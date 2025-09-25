#!/bin/bash
# Sing-box 高级部署脚本 (VLESS + HY2 + QR + Let's Encrypt)
# 支持无域名模式，自动开启防火墙端口
# Author: ChatGPT

set -e

echo "=================== Sing-box 高级部署 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖 (兼容所有 Debian/Ubuntu)
apt update -y
DEPS="curl socat cron openssl qrencode netcat-openbsd"
apt install -y $DEPS

# 安装 acme.sh (用于有域名模式)
if ! command -v acme.sh &>/dev/null; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi

# 设置默认 CA 为 Let's Encrypt
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

# 用户选择节点模式
echo "请选择节点模式:"
echo "1) 有域名 (自动申请 TLS)"
echo "2) 无域名 (使用 VPS IP, 不启用 TLS)"
read -rp "请输入 1 或 2: " NODE_MODE

# 用户输入域名或获取 VPS IP
if [[ "$NODE_MODE" == "1" ]]; then
    read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " DOMAIN
    # 检查域名是否解析到当前 VPS
    VPS_IP=$(curl -s ipv4.icanhazip.com)
    DOMAIN_IP=$(dig +short "$DOMAIN" A)
    if [[ "$VPS_IP" != "$DOMAIN_IP" ]]; then
        echo "域名解析不正确: $DOMAIN -> $DOMAIN_IP, VPS IP: $VPS_IP"
        echo "请确保域名解析正确再运行脚本"
        exit 1
    fi
fi

# 随机端口函数
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# 用户输入端口
read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
[[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]] && VLESS_PORT=$(get_random_port)

read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]] && HY2_PORT=$(get_random_port)

# UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# TLS 证书目录 (仅有域名模式)
if [[ "$NODE_MODE" == "1" ]]; then
    CERT_DIR="/etc/ssl/$DOMAIN"
    mkdir -p "$CERT_DIR"
    echo ">>> 申请 Let's Encrypt TLS 证书"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
      --key-file       "$CERT_DIR/privkey.pem" \
      --fullchain-file "$CERT_DIR/fullchain.pem" --force
fi

# 生成 sing-box 配置
CONFIG_FILE="/etc/sing-box/config.json"
mkdir -p "$(dirname $CONFIG_FILE)"

if [[ "$NODE_MODE" == "1" ]]; then
cat > $CONFIG_FILE <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      }
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF
else
IP=$(curl -s ipv4.icanhazip.com)
cat > $CONFIG_FILE <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID" }],
      "tls": { "enabled": false }
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      "tls": { "enabled": false }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF
fi

# 启动 sing-box
systemctl enable sing-box
systemctl restart sing-box
sleep 5

# 自动开放防火墙端口 (Debian/Ubuntu)
ufw allow $VLESS_PORT/tcp 2>/dev/null || true
ufw allow $HY2_PORT/udp 2>/dev/null || true
iptables -I INPUT -p tcp --dport $VLESS_PORT -j ACCEPT
iptables -I INPUT -p udp --dport $HY2_PORT -j ACCEPT

# 生成 URI
if [[ "$NODE_MODE" == "1" ]]; then
    VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp&flow=xtls-rprx-vision#VLESS-$DOMAIN"
    HY2_URI="hysteria2://$HY2_PASS@$DOMAIN:$HY2_PORT?sni=$DOMAIN#HY2-$DOMAIN"
else
    VLESS_URI="vless://$UUID@$IP:$VLESS_PORT?encryption=none&type=tcp#VLESS-$IP"
    HY2_URI="hysteria2://$HY2_PASS@$IP:$HY2_PORT?insecure=1#HY2-$IP"
fi

# 生成二维码
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png

# 节点信息
echo "=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"

# TCP/UDP 端口自检 (本地)
echo
echo "=================== 端口自检 ==================="
sleep 3
nc -zv 127.0.0.1 $VLESS_PORT >/dev/null 2>&1 && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
timeout 1 bash -c "echo > /dev/udp/127.0.0.1/$HY2_PORT" 2>/dev/null && echo "[✔] HY2 UDP $HY2_PORT 已监听" || echo "[✖] HY2 UDP $HY2_PORT 未监听"

# rev 快捷方式
REV_SH="/root/show_singbox_nodes.sh"
cat > $REV_SH <<EOF
#!/bin/bash
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"
EOF
chmod +x $REV_SH
echo "快捷显示节点: 输入 rev (先运行 source ~/.bashrc)"
echo "卸载: 输入 ./uninstall_singbox.sh"

# alias 添加 rev
if ! grep -q "alias rev=" ~/.bashrc; then
    echo "alias rev='$REV_SH'" >> ~/.bashrc
    source ~/.bashrc
fi

# 自动重启 sing-box 并刷新二维码函数
echo
echo "如需刷新节点/二维码，请运行: $REV_SH 并重启 sing-box"

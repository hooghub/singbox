#!/bin/bash
# Sing-box 高级部署脚本 (VLESS + HY2 + 自动端口 + QR + Let's Encrypt)
# 支持有域名/无域名模式
# Author: ChatGPT

set -e

echo "=================== Sing-box 高级部署 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖 (兼容所有 Debian/Ubuntu)
apt update -y
apt install -y curl socat cron openssl qrencode netcat-openbsd

# 安装 acme.sh
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

# 用户选择模式
echo "请选择节点模式:"
echo "1) 有域名 (自动申请 TLS)"
echo "2) 无域名 (使用 VPS IP, 不启用 TLS)"
read -rp "请输入 1 或 2: " MODE

if [[ "$MODE" == "1" ]]; then
    read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " DOMAIN
    # 检查域名是否指向当前 VPS
    VPS_IP=$(curl -s https://ipinfo.io/ip)
    DOMAIN_IP=$(dig +short "$DOMAIN" @8.8.8.8 | tail -n1)
    if [[ "$VPS_IP" != "$DOMAIN_IP" ]]; then
        echo "域名未指向本 VPS IP ($VPS_IP)，请先解析域名。"
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

# 生成 UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# TLS 证书目录
CERT_DIR="/etc/ssl/singbox"
mkdir -p "$CERT_DIR"

if [[ "$MODE" == "1" ]]; then
    echo ">>> 申请 Let's Encrypt TLS 证书"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file       "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" --force
    TLS_ENABLED=true
else
    DOMAIN=$(curl -s https://ipinfo.io/ip)
    TLS_ENABLED=false
fi

# 生成 sing-box 配置
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID" }],
      "tls": { "enabled": $TLS_ENABLED$( [[ "$TLS_ENABLED" == true ]] && echo ",\"server_name\":\"$DOMAIN\",\"certificate_path\":\"$CERT_DIR/fullchain.pem\",\"key_path\":\"$CERT_DIR/privkey.pem\"" || echo "") }
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      "tls": { "enabled": $TLS_ENABLED$( [[ "$TLS_ENABLED" == true ]] && echo ",\"server_name\":\"$DOMAIN\",\"certificate_path\":\"$CERT_DIR/fullchain.pem\",\"key_path\":\"$CERT_DIR/privkey.pem\"" || echo "") }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

# 启动 sing-box
systemctl enable sing-box
systemctl restart sing-box
sleep 3

# 自动重启刷新二维码函数
generate_qr() {
    VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&type=tcp#VLESS-$DOMAIN"
    HY2_URI="hysteria2://$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=1#HY2-$DOMAIN"
    echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
    echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
}

generate_qr

# 端口自检
check_ports() {
    echo
    echo "=================== 端口自检 ==================="
    # TCP
    timeout 2 nc -z 127.0.0.1 $VLESS_PORT &>/dev/null && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
    # UDP
    timeout 2 bash -c "echo > /dev/udp/127.0.0.1/$HY2_PORT" &>/dev/null && echo "[✔] HY2 UDP $HY2_PORT 已监听" || echo "[✖] HY2 UDP $HY2_PORT 未监听"
}

check_ports

# 显示节点信息
echo
echo "=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"

# 创建 rev 快捷方式
cat > /usr/local/bin/rev <<EOF
#!/bin/bash
echo "=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"
EOF
chmod +x /usr/local/bin/rev
echo
echo "快捷显示节点: 输入 rev"
echo "卸载: 输入 ./uninstall_singbox.sh"

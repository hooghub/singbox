#!/bin/bash
# Sing-box 高级一键部署脚本 (VLESS + HY2 + 自动端口 + QR + Let's Encrypt兼容)
# Author: ChatGPT

set -e

echo "=================== Sing-box 高级部署 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖 (兼容所有 Debian/Ubuntu)
apt update -y
apt install -y curl socat cron openssl qrencode netcat-openbsd || apt install -y netcat-traditional

# 安装 acme.sh
if ! command -v acme.sh &>/dev/null; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

# 用户选择节点模式
echo "请选择节点模式:"
echo "1) 有域名 (自动申请 TLS)"
echo "2) 无域名 (使用 VPS IP, 不启用 TLS)"
read -rp "请输入 1 或 2: " NODE_MODE
NODE_MODE=${NODE_MODE:-1}

# 随机端口函数
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# 端口输入
read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-443}
[[ "$VLESS_PORT" == "0" ]] && VLESS_PORT=$(get_random_port)

read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
HY2_PORT=${HY2_PORT:-8443}
[[ "$HY2_PORT" == "0" ]] && HY2_PORT=$(get_random_port)

# UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

CERT_DIR="/etc/ssl/singbox"
mkdir -p "$CERT_DIR"

TLS_ENABLED=false
SERVER_NAME=""
if [[ "$NODE_MODE" == "1" ]]; then
    # 有域名模式
    read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " SERVER_NAME
    TLS_ENABLED=true

    # 检查域名解析
    VPS_IP=$(curl -s https://api.ipify.org)
    DOMAIN_IP=$(dig +short $SERVER_NAME @8.8.8.8 | tail -n1)
    if [[ "$DOMAIN_IP" != "$VPS_IP" ]]; then
        echo "域名 $SERVER_NAME 未解析到本 VPS ($VPS_IP)，请先解析再运行"
        exit 1
    fi

    echo ">>> 申请 Let's Encrypt TLS 证书"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d "$SERVER_NAME" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$SERVER_NAME" --ecc \
      --key-file       "$CERT_DIR/privkey.pem" \
      --fullchain-file "$CERT_DIR/fullchain.pem" --force

    # 证书自动续签 30天一次
    (crontab -l 2>/dev/null; echo "0 3 */30 * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null && systemctl restart sing-box") | crontab -
fi

# 生成 sing-box 配置
CONFIG_FILE="/etc/sing-box/config.json"

if $TLS_ENABLED; then
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
        "server_name": "$SERVER_NAME",
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
        "server_name": "$SERVER_NAME",
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF
else
IP=$(curl -s https://api.ipify.org)
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
sleep 3

# 防火墙开放端口 (兼容 ufw/iptables)
if command -v ufw >/dev/null 2>&1; then
    ufw allow $VLESS_PORT/tcp >/dev/null 2>&1 || true
    ufw allow $HY2_PORT/udp >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport $VLESS_PORT -j ACCEPT
    iptables -I INPUT -p udp --dport $HY2_PORT -j ACCEPT
else
    echo "未检测到 ufw 或 iptables，请确保 VPS 防火墙允许端口 $VLESS_PORT TCP 和 $HY2_PORT UDP"
fi

# 生成 URI
if $TLS_ENABLED; then
    VLESS_URI="vless://$UUID@$SERVER_NAME:$VLESS_PORT?encryption=none&security=tls&sni=$SERVER_NAME&type=tcp&flow=xtls-rprx-vision#VLESS-$SERVER_NAME"
    HY2_URI="hysteria2://hy2user:$HY2_PASS@$SERVER_NAME:$HY2_PORT?sni=$SERVER_NAME#HY2-$SERVER_NAME"
else
    VLESS_URI="vless://$UUID@$IP:$VLESS_PORT?encryption=none&type=tcp#VLESS-$IP"
    HY2_URI="hysteria2://hy2user:$HY2_PASS@$IP:$HY2_PORT?insecure=1#HY2-$IP"
fi

# 生成二维码
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png

# 节点信息显示
echo
echo "=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"

# 端口自检
echo
echo "=================== 端口自检 ==================="
sleep 1
if nc -zv 127.0.0.1 $VLESS_PORT >/dev/null 2>&1; then
    echo "[✔] VLESS TCP $VLESS_PORT 已监听"
else
    echo "[✖] VLESS TCP $VLESS_PORT 未监听"
fi

# UDP 简单检测 (HY2)
sleep 1
if command -v nc >/dev/null 2>&1; then
    (echo > /dev/udp/127.0.0.1/$HY2_PORT) >/dev/null 2>&1 && echo "[✔] HY2 UDP $HY2_PORT 已监听" || echo "[✖] HY2 UDP $HY2_PORT 未监听"
else
    echo "未检测到 nc 命令，无法检测 HY2 UDP 端口"
fi

# 创建 rev 快捷方式
REV_FILE="/usr/local/bin/rev_singbox"
cat > $REV_FILE <<EOF
#!/bin/bash
echo "===

#!/bin/bash
# Sing-box 一键部署脚本 (VLESS + HY2 + TLS/NoTLS + QR)
# Author: ChatGPT
set -e

echo "=================== Sing-box 高级部署 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖
apt update -y
apt install -y curl socat cron openssl qrencode dnsutils || true
if ! apt install -y netcat-openbsd; then
    apt install -y netcat-traditional
fi

# 安装 acme.sh
if ! command -v acme.sh &>/dev/null; then
    curl https://get.acme.sh | sh
    source ~/.bashrc || true
fi

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

# 随机端口函数
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q ":$PORT " || break
    done
    echo $PORT
}

# 选择模式
echo "请选择节点模式:"
echo "1) 有域名 (自动申请 TLS)"
echo "2) 无域名 (使用 VPS IP, 不启用 TLS)"
read -rp "请输入 1 或 2: " MODE

VLESS_PORT=""
HY2_PORT=""
DOMAIN=""
TLS_ENABLED=false

if [[ "$MODE" == "1" ]]; then
    read -rp "请输入你的域名: " DOMAIN
    TLS_ENABLED=true
    read -rp "请输入 VLESS TCP 端口 (默认443, 输入0随机): " VLESS_PORT
    read -rp "请输入 HY2 UDP 端口 (默认8443, 输入0随机): " HY2_PORT
else
    DOMAIN=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
    read -rp "请输入 VLESS TCP 端口 (默认 50000, 输入0随机): " VLESS_PORT
    read -rp "请输入 HY2 UDP 端口 (默认 50001, 输入0随机): " HY2_PORT
fi

# 端口设置
[[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]] && VLESS_PORT=$(get_random_port)
[[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]] && HY2_PORT=$(get_random_port)

# UUID / HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

CERT_DIR="/etc/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

# TLS 证书
if $TLS_ENABLED; then
    VPS_IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
    DOMAIN_IP=$(dig +short $DOMAIN | tail -n1)
    if [[ "$VPS_IP" != "$DOMAIN_IP" ]]; then
        echo "❌ 域名未解析到当前 VPS IP: $VPS_IP"
        exit 1
    fi
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" --force
fi

# 生成配置
CONFIG_FILE="/etc/sing-box/config.json"
cat > $CONFIG_FILE <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID" }],
      "tls": { "enabled": $TLS_ENABLED$( $TLS_ENABLED && echo ", \"certificate_path\": \"$CERT_DIR/fullchain.pem\", \"key_path\": \"$CERT_DIR/privkey.pem\"" ) }
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      "tls": { "enabled": $TLS_ENABLED$( $TLS_ENABLED && echo ", \"certificate_path\": \"$CERT_DIR/fullchain.pem\", \"key_path\": \"$CERT_DIR/privkey.pem\"" ) }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

# 启动服务
systemctl enable sing-box
systemctl restart sing-box
sleep 3

# 节点链接
if $TLS_ENABLED; then
    VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&type=tcp#VLESS-$DOMAIN"
    HY2_URI="hysteria2://hy2user:$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=0#HY2-$DOMAIN"
else
    VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&type=tcp#VLESS-$DOMAIN"
    HY2_URI="hysteria2://hy2user:$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=1#HY2-$DOMAIN"
fi

# 二维码
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png

# 端口检测
echo -e "\n=================== 端口自检 ==================="
VLESS_STATUS="[✖]"
HY2_STATUS="[✖]"
nc -z -v -w 2 127.0.0.1 $VLESS_PORT &>/dev/null && VLESS_STATUS="[✔]"
bash -c "echo > /dev/udp/127.0.0.1/$HY2_PORT" &>/dev/null && HY2_STATUS="[✔]"
echo "$VLESS_STATUS VLESS TCP $VLESS_PORT"
echo "$HY2_STATUS HY2 UDP $HY2_PORT"

# 输出信息
echo -e "\n=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo -e "二维码文件:\n/root/vless_qr.png\n/root/hy2_qr.png"

# rev 快捷方式
REV_FILE="/usr/local/bin/rev"
cat > $REV_FILE <<EOF
#!/bin/bash
echo -e "VLESS 节点:\\n$VLESS_URI"
echo -e "HY2 节点:\\n$HY2_URI"
echo -e "二维码文件:\\n/root/vless_qr.png\\n/root/hy2_qr.png"
EOF
chmod +x $REV_FILE
echo "快捷显示节点: 输入 rev"

# 卸载脚本
UNINSTALL_FILE="./uninstall_singbox.sh"
cat > $UNINSTALL_FILE <<'EOF'
#!/bin/bash
systemctl stop sing-box
systemctl disable sing-box
rm -f /etc/sing-box/config.json
rm -f /root/vless_qr.png /root/hy2_qr.png
rm -f /usr/local/bin/rev
echo "Sing-box 已卸载"
EOF
chmod +x $UNINSTALL_FILE
echo "卸载: 输入 ./uninstall_singbox.sh"

echo "=================== 部署完成 ==================="

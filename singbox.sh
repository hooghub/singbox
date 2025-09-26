#!/bin/bash
# Sing-box 一键安装部署脚本
# Author: ChatGPT
set -e

echo "=================== Sing-box 一键部署 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖
apt update -y
apt install -y curl socat cron openssl qrencode dnsutils jq

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

# 选择模式
echo "请选择节点模式："
echo "1) 无域名 (使用 VPS IP, TLS关闭)"
echo "2) 有域名 (自动申请 TLS)"
read -rp "请输入 1 或 2: " NODE_TYPE

if [[ "$NODE_TYPE" == "2" ]]; then
    USE_TLS=true
    read -rp "请输入域名: " DOMAIN
    SERVER_IP=$(curl -s ipv4.icanhazip.com)
    DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
    if [[ -z "$DOMAIN_IP" || "$DOMAIN_IP" != "$SERVER_IP" ]]; then
        echo "[✖] 域名未正确解析到 VPS IP ($SERVER_IP)"
        exit 1
    fi
    echo "[✔] 域名解析正确"

    CERT_DIR="/etc/ssl/$DOMAIN"
    mkdir -p "$CERT_DIR"

    # 安装 acme.sh
    if ! command -v acme.sh &>/dev/null; then
        curl https://get.acme.sh | sh
        source ~/.bashrc
    fi

    # 申请证书
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
      --key-file "$CERT_DIR/privkey.pem" \
      --fullchain-file "$CERT_DIR/fullchain.pem" --force

    # 自动续签
    (crontab -l 2>/dev/null | grep -v 'acme.sh'; echo "0 3 */30 * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null && systemctl restart sing-box") | crontab -
else
    USE_TLS=false
fi

# 随机端口函数
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q ":$PORT" || break
    done
    echo $PORT
}

read -rp "请输入 VLESS TCP 端口 (默认0随机): " VLESS_PORT
[[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]] && VLESS_PORT=$(get_random_port)

read -rp "请输入 HY2 UDP 端口 (默认0随机): " HY2_PORT
[[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]] && HY2_PORT=$(get_random_port)

# UUID / 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# 最小可运行配置
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
      "transport": { "type": "tcp" },
      "tls": { "enabled": $( [[ "$USE_TLS" == true ]] && echo true || echo false )$( [[ "$USE_TLS" == true ]] && echo ", \"server_name\": \"$DOMAIN\", \"certificate_path\": \"$CERT_DIR/fullchain.pem\", \"key_path\": \"$CERT_DIR/privkey.pem\"" ) }
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      "tls": { "enabled": $( [[ "$USE_TLS" == true ]] && echo true || echo false )$( [[ "$USE_TLS" == true ]] && echo ", \"server_name\": \"$DOMAIN\", \"certificate_path\": \"$CERT_DIR/fullchain.pem\", \"key_path\": \"$CERT_DIR/privkey.pem\"" ) }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

# 节点 URI
IP=$(curl -s ipv4.icanhazip.com)
if [[ "$USE_TLS" == true ]]; then
    VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&type=tcp#VLESS-$DOMAIN"
    HY2_URI="hysteria2://$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=0&sni=$DOMAIN#HY2-$DOMAIN"
else
    VLESS_URI="vless://$UUID@$IP:$VLESS_PORT?encryption=none&type=tcp#VLESS-noTLS"
    HY2_URI="hysteria2://$HY2_PASS@$IP:$HY2_PORT?insecure=1#HY2-noTLS"
fi

# 保存节点信息
cat > /root/singbox_nodes.env <<EOF
VLESS_URI="$VLESS_URI"
HY2_URI="$HY2_URI"
EOF

# 显示节点脚本
cat > /root/show_singbox_nodes.sh <<'EOF'
#!/bin/bash
source /root/singbox_nodes.env
echo -e "\n=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo -e "\nVLESS QR:"; echo "$VLESS_URI" | qrencode -t ansiutf8
echo -e "\nHY2 QR:"; echo "$HY2_URI" | qrencode -t ansiutf8
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
echo -e "\n二维码文件已生成：/root/vless_qr.png 和 /root/hy2_qr.png"
EOF
chmod +x /root/show_singbox_nodes.sh

# rev 别名
if ! grep -q "alias rev=" ~/.bashrc; then
    echo "alias rev='/root/show_singbox_nodes.sh'" >> ~/.bashrc
fi

# 启动服务
systemctl enable sing-box
systemctl restart sing-box
sleep 3

# 端口检查
echo
[[ -n "$(ss -tlnp | grep ":$VLESS_PORT ")" ]] && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
[[ -n "$(ss -ulnp | grep ":$HY2_PORT ")" ]] && echo "[✔] HY2 UDP $HY2_PORT 已监听" || echo "[✖] HY2 UDP $HY2_PORT 未监听"

# 显示节点
source /root/show_singbox_nodes.sh

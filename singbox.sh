#!/bin/bash
# Sing-box 高级部署脚本 (最终可运行版)
set -e

echo "=================== Sing-box 部署 ==================="

[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

apt update -y
apt install -y curl socat cron openssl qrencode dnsutils

# 安装 acme.sh
if ! command -v acme.sh &>/dev/null; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

echo "请选择节点模式:"
echo "1) 有域名 (自动申请 TLS)"
echo "2) 无域名 (使用 VPS IP, 不启用 TLS)"
read -rp "请输入 1 或 2: " MODE

if [[ "$MODE" == "1" ]]; then
    read -rp "请输入你的域名: " DOMAIN
fi

read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
[[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]] && VLESS_PORT=$(get_random_port)

read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]] && HY2_PORT=$(get_random_port)

UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

if [[ "$MODE" == "1" ]]; then
    CERT_DIR="/etc/ssl/$DOMAIN"
    mkdir -p "$CERT_DIR"
    VPS_IP=$(curl -s https://api.ipify.org)
    DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)
    if [[ "$VPS_IP" != "$DOMAIN_IP" ]]; then
        echo "[✖] 域名 $DOMAIN 没有指向本 VPS ($VPS_IP)"
        exit 1
    fi
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
      --key-file "$CERT_DIR/privkey.pem" \
      --fullchain-file "$CERT_DIR/fullchain.pem" --force
    (crontab -l 2>/dev/null; echo "0 3 */30 * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null && systemctl restart sing-box") | crontab -
fi

CONFIG_FILE="/etc/sing-box/config.json"
mkdir -p $(dirname "$CONFIG_FILE")

if [[ "$MODE" == "1" ]]; then
cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{"uuid":"$UUID","flow":"xtls-rprx-vision"}],
      "tls": {"enabled": true,"server_name":"$DOMAIN","certificate_path":"$CERT_DIR/fullchain.pem","key_path":"$CERT_DIR/privkey.pem"}
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{"password":"$HY2_PASS"}],
      "tls": {"enabled": true,"server_name":"$DOMAIN","certificate_path":"$CERT_DIR/fullchain.pem","key_path":"$CERT_DIR/privkey.pem"}
    }
  ],
  "outbounds":[{"type":"direct"}]
}
EOF
else
VPS_IP=$(curl -s https://api.ipify.org)
cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{"uuid":"$UUID"}],
      "tls": {"enabled": false}
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{"password":"$HY2_PASS"}],
      "tls": {"enabled": false},
      "udp": {"enabled": true}
    }
  ],
  "outbounds":[{"type":"direct"}]
}
EOF
fi

systemctl enable sing-box
systemctl restart sing-box
sleep 3

# 节点 URI
if [[ "$MODE" == "1" ]]; then
    VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp&flow=xtls-rprx-vision#VLESS-$DOMAIN"
    HY2_URI="hysteria2://$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=0&sni=$DOMAIN#HY2-$DOMAIN"
else
    VLESS_URI="vless://$UUID@$VPS_IP:$VLESS_PORT?encryption=none&type=tcp#VLESS-$VPS_IP"
    HY2_URI="hysteria2://$HY2_PASS@$VPS_IP:$HY2_PORT?insecure=1#HY2-$VPS_IP"
fi

# 生成二维码
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png

# 节点显示脚本
cat > /root/show_singbox_nodes.sh <<'EON'
#!/bin/bash
VLESS_URI='"$VLESS_URI"'
HY2_URI='"$HY2_URI"'
VLESS_PORT='"$VLESS_PORT"'
HY2_PORT='"$HY2_PORT"'
echo "=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"
echo
echo "=================== 端口自检 ==================="
check_ports() {
    if [[ -n "$(ss -tulnp | grep $VLESS_PORT)" ]]; then
        echo "[✔] VLESS TCP $VLESS_PORT 已监听"
    else
        echo "[✖] VLESS TCP $VLESS_PORT 未监听"
    fi
    if [[ -n "$(ss -ulnp | grep $HY2_PORT)" ]]; then
        echo "[✔] HY2 UDP $HY2_PORT 已监听"
    else
        echo "[✖] HY2 UDP $HY2_PORT 未监听"
    fi
}
check_ports
EON

chmod +x /root/show_singbox_nodes.sh

# rev 别名
grep -qxF 'alias rev="/root/show_singbox_nodes.sh"' ~/.bashrc || echo 'alias rev="/root/show_singbox_nodes.sh"' >> ~/.bashrc
source ~/.bashrc

# 卸载脚本
cat > /root/uninstall_singbox.sh <<'EON'
#!/bin/bash
systemctl stop sing-box
systemctl disable sing-box
rm -f /etc/sing-box/config.json
rm -f /root/vless_qr.png /root/hy2_qr.png /root/show_singbox_nodes.sh
sed -i '/alias rev=\/root\/show_singbox_nodes.sh/d' ~/.bashrc
echo "Sing-box 已卸载"
EON
chmod +x /root/uninstall_singbox.sh

echo "=================== 部署完成 ==================="
echo "VLESS QR: /root/vless_qr.png"
echo "HY2 QR: /root/hy2_qr.png"
echo "快捷显示节点: 输入 rev"
echo "卸载: 输入 ./uninstall_singbox.sh"

# 自动端口自检
/root/show_singbox_nodes.sh

#!/bin/bash
# Sing-box 高级部署脚本 (VLESS + HY2 + QR + rev + Let’s Encrypt / 无域名模式 + 自动重启 + TCP/UDP 连通性检测)
# Author: ChatGPT

set -e

echo "=================== Sing-box 高级部署 ==================="

[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

apt update -y
apt install -y curl socat cron openssl qrencode netcat

# 安装 acme.sh
if ! command -v acme.sh &>/dev/null; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

echo "请选择节点模式:"
echo "1) 有域名 (自动申请 TLS)"
echo "2) 无域名 (使用 VPS IP, 不启用 TLS)"
read -rp "请输入 1 或 2: " MODE

if [[ "$MODE" == "1" ]]; then
    read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " DOMAIN
    VPS_IP=$(curl -4s https://ip.gs)
    DOMAIN_IP=$(dig +short "$DOMAIN" | head -n1)
    if [[ "$DOMAIN_IP" != "$VPS_IP" ]]; then
        echo "[✖] 域名 $DOMAIN 未指向当前 VPS IP ($VPS_IP)，请修改解析后再运行"
        exit 1
    fi
    TLS_ENABLED=true
    CERT_DIR="/etc/ssl/$DOMAIN"
    mkdir -p "$CERT_DIR"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" --force
    (crontab -l 2>/dev/null; echo "0 3 */30 * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null && systemctl restart sing-box") | crontab -
else
    TLS_ENABLED=false
    DOMAIN=$(curl -4s https://ip.gs)
fi

get_random_port() { while :; do PORT=$((RANDOM%50000+10000)); ss -tuln | grep -q $PORT || break; done; echo $PORT; }

read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
[[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]] && VLESS_PORT=$(get_random_port)

read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]] && HY2_PORT=$(get_random_port)

UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

CONFIG_FILE="/etc/sing-box/config.json"
mkdir -p $(dirname "$CONFIG_FILE")

cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID" }],
      "tls": { "enabled": $TLS_ENABLED $(if $TLS_ENABLED; then echo ", \"server_name\": \"$DOMAIN\", \"certificate_path\": \"$CERT_DIR/fullchain.pem\", \"key_path\": \"$CERT_DIR/privkey.pem\""; fi) }
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      "tls": { "enabled": $TLS_ENABLED },
      "udp": { "enabled": true }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

systemctl enable sing-box
systemctl restart sing-box

# 延迟端口自检和连通性测试
sleep 5
MAX_CHECK=3

check_ports() {
    local vless_ok=false
    local hy2_ok=false
    nc -zv 127.0.0.1 $VLESS_PORT &>/dev/null && vless_ok=true
    timeout 2 bash -c "echo > /dev/udp/127.0.0.1/$HY2_PORT" &>/dev/null && hy2_ok=true
    echo "$vless_ok $hy2_ok"
}

for i in $(seq 1 $MAX_CHECK); do
    read VLESS_OK HY2_OK <<< $(check_ports)
    if [[ "$VLESS_OK" == "true" && "$HY2_OK" == "true" ]]; then
        break
    else
        echo "端口未全部连通，自动重启 sing-box 并刷新二维码 ($i/$MAX_CHECK)"
        systemctl restart sing-box
        sleep 5
        # 重新生成二维码
        VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&type=tcp#VLESS-$DOMAIN"
        HY2_URI="hysteria2://hy2user:$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=1#HY2-$DOMAIN"
        echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
        echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
    fi
done

VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&type=tcp#VLESS-$DOMAIN"
HY2_URI="hysteria2://hy2user:$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=1#HY2-$DOMAIN"

echo
echo "=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo -e "二维码文件:\n/root/vless_qr.png\n/root/hy2_qr.png"

echo
echo "=================== 端口连通性自检 ==================="
[[ "$VLESS_OK" == "true" ]] && echo "[✔] VLESS TCP $VLESS_PORT 可连通" || echo "[✖] VLESS TCP $VLESS_PORT 不可连通"
[[ "$HY2_OK" == "true" ]] && echo "[✔] HY2 UDP $HY2_PORT 可连通" || echo "[✖] HY2 UDP $HY2_PORT 不可连通"

# rev 快捷
cat > /root/show_singbox_nodes.sh <<EOF
#!/bin/bash
echo -e "VLESS 节点:\\n$VLESS_URI"
echo -e "HY2 节点:\\n$HY2_URI"
echo -e "二维码文件:\\n/root/vless_qr.png\\n/root/hy2_qr.png"
EOF
chmod +x /root/show_singbox_nodes.sh
grep -q 'alias rev=' /etc/profile || echo 'alias rev="/root/show_singbox_nodes.sh"' >> /etc/profile
source /etc/profile

# 卸载快捷
cat > /root/uninstall_singbox.sh <<EOF
#!/bin/bash
systemctl stop sing-box
systemctl disable sing-box
apt remove -y sing-box
rm -rf /etc/sing-box /root/vless_qr.png /root/hy2_qr.png /root/show_singbox_nodes.sh /root/uninstall_singbox.sh
echo "Sing-box 已卸载完成"
EOF
chmod +x /root/uninstall_singbox.sh

echo "=================== 部署完成 ==================="
echo "快捷显示节点: 输入 rev"
echo "卸载: 输入 ./uninstall_singbox.sh"

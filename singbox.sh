#!/bin/bash
# Sing-box 高级一键部署脚本 (VLESS + HY2 + QR + Let's Encrypt + rev快捷)
# Author: ChatGPT
set -e

echo "=================== Sing-box 高级部署 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖 (兼容 Debian/Ubuntu)
apt update -y
DEPS=(curl socat cron openssl qrencode netcat-openbsd)
for pkg in "${DEPS[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        apt install -y "$pkg"
    fi
done

# 安装 acme.sh
if ! command -v acme.sh &>/dev/null; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

# 选择模式
echo "请选择节点模式:"
echo "1) 有域名 (自动申请 TLS)"
echo "2) 无域名 (使用 VPS IP, 不启用 TLS)"
read -rp "请输入 1 或 2: " MODE

if [[ "$MODE" == "1" ]]; then
    read -rp "请输入你的域名: " DOMAIN
    USE_TLS=1
else
    DOMAIN=$(curl -s https://ipinfo.io/ip)
    USE_TLS=0
fi

# 随机端口函数
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# VLESS TCP 端口
read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
[[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]] && VLESS_PORT=$(get_random_port)

# HY2 UDP 端口
read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]] && HY2_PORT=$(get_random_port)

# UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# TLS 证书目录
CERT_DIR="/etc/ssl/$DOMAIN"
[[ $USE_TLS -eq 1 ]] && mkdir -p "$CERT_DIR"

# 申请证书
if [[ $USE_TLS -eq 1 ]]; then
    echo ">>> 申请 Let's Encrypt TLS 证书"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" --force
    # 30天自动续签
    (crontab -l 2>/dev/null; echo "0 3 */30 * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null && systemctl restart sing-box") | crontab -
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
      "tls": {
        "enabled": $USE_TLS,
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
      "tls": { "enabled": $USE_TLS }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

# 防火墙开放端口 (兼容无 iptables 系统)
if command -v ufw >/dev/null 2>&1; then
    ufw allow $VLESS_PORT/tcp >/dev/null 2>&1 || true
    ufw allow $HY2_PORT/udp >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport $VLESS_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $VLESS_PORT -j ACCEPT
    iptables -C INPUT -p udp --dport $HY2_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport $HY2_PORT -j ACCEPT
else
    echo "未检测到 ufw 或 iptables，请确保 VPS 防火墙允许端口 $VLESS_PORT TCP 和 $HY2_PORT UDP"
fi

# 启动 sing-box
systemctl enable sing-box
systemctl restart sing-box
sleep 5

# 生成节点信息和二维码
VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&type=tcp#VLESS-$DOMAIN"
HY2_URI="hysteria2://hy2user:$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=$((1-USE_TLS))#HY2-$DOMAIN"
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png

# 检查端口监听
echo
echo "=================== 端口自检 ==================="
sleep 2
nc -zv -w 2 127.0.0.1 $VLESS_PORT &>/dev/null && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
nc -zu -w 2 127.0.0.1 $HY2_PORT &>/dev/null && echo "[✔] HY2 UDP $HY2_PORT 已监听" || echo "[✖] HY2 UDP $HY2_PORT 未监听"

# 显示节点信息
echo
echo "=================== 节点信息 ==================="
echo "VLESS 节点:"
echo "$VLESS_URI"
echo "HY2 节点:"
echo "$HY2_URI"
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"

# 创建 rev 快捷方式
cat > /root/show_singbox_nodes.sh <<'EOL'
#!/bin/bash
echo "VLESS 节点:"
cat /root/vless_uri.txt
echo "HY2 节点:"
cat /root/hy2_uri.txt
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"
EOL
chmod +x /root/show_singbox_nodes.sh
ln -sf /root/show_singbox_nodes.sh /usr/local/bin/rev

# 保存节点 URI
echo "$VLESS_URI" > /root/vless_uri.txt
echo "$HY2_URI" > /root/hy2_uri.txt

echo
echo "快捷显示节点: 输入 rev"
echo "卸载: 输入 ./uninstall_singbox.sh"

#!/bin/bash
# Sing-box 高级一键部署脚本 (Let’s Encrypt + 无域名模式修正版)
set -e

echo "=================== Sing-box 高级部署 ==================="

[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖 (兼容 Debian/Ubuntu)
apt update -y
apt install -y curl socat cron openssl qrencode netcat-openbsd || apt install -y netcat-traditional

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

# 获取 VPS IPv4
VPS_IP=$(curl -4s https://ip.sb | tr -d '[:space:]')
if [[ -z "$VPS_IP" ]]; then
    echo "[✖] 无法获取 VPS IP"
    exit 1
fi

echo "请选择节点模式:"
echo "1) 有域名 (自动申请 TLS)"
echo "2) 无域名 (使用 VPS IP, 不启用 TLS)"
read -rp "请输入 1 或 2: " NODE_MODE

if [[ "$NODE_MODE" == "1" ]]; then
    read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " DOMAIN
    DOMAIN_IP=$(dig +short $DOMAIN | head -n1)
    if [[ "$DOMAIN_IP" != "$VPS_IP" ]]; then
        echo "[✖] 域名未解析到本 VPS IP $VPS_IP"
        exit 1
    fi
fi

get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
[[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]] && VLESS_PORT=$(get_random_port)

read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]] && HY2_PORT=$(get_random_port)

UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

CONFIG_FILE="/etc/sing-box/config.json"
CERT_DIR="/etc/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

TLS_JSON=""
if [[ "$NODE_MODE" == "1" ]]; then
    echo ">>> 申请 Let's Encrypt TLS 证书"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
      --key-file "$CERT_DIR/privkey.pem" \
      --fullchain-file "$CERT_DIR/fullchain.pem" --force
    TLS_JSON=",\"tls\":{\"enabled\":true,\"server_name\":\"$DOMAIN\",\"certificate_path\":\"$CERT_DIR/fullchain.pem\",\"key_path\":\"$CERT_DIR/privkey.pem\"}"
fi

# 生成配置文件
if [[ "$NODE_MODE" == "1" ]]; then
cat > $CONFIG_FILE <<EOF
{
  "log":{"level":"info"},
  "inbounds":[
    {"type":"vless","listen":"0.0.0.0","listen_port":$VLESS_PORT,"users":[{"uuid":"$UUID","flow":"xtls-rprx-vision"}]$TLS_JSON},
    {"type":"hysteria2","listen":"0.0.0.0","listen_port":$HY2_PORT,"users":[{"password":"$HY2_PASS"}]$TLS_JSON}
  ],
  "outbounds":[{"type":"direct"}]
}
EOF
else
cat > $CONFIG_FILE <<EOF
{
  "log":{"level":"info"},
  "inbounds":[
    {"type":"vless","listen":"0.0.0.0","listen_port":$VLESS_PORT,"users":[{"uuid":"$UUID"}]},
    {"type":"hysteria2","listen":"0.0.0.0","listen_port":$HY2_PORT,"users":[{"password":"$HY2_PASS"}]}
  ],
  "outbounds":[{"type":"direct"}]
}
EOF
fi

# 启动 sing-box
systemctl enable sing-box
systemctl restart sing-box
sleep 5

# 端口检查
check_tcp() { nc -zv 127.0.0.1 $1 &>/dev/null && echo "[✔] VLESS TCP $1 已监听" || echo "[✖] VLESS TCP $1 未监听"; }
check_udp() { timeout 2 bash -c "echo > /dev/udp/127.0.0.1/$1" &>/dev/null && echo "[✔] HY2 UDP $1 已监听" || echo "[✖] HY2 UDP $1 未监听"; }

echo
check_tcp $VLESS_PORT
check_udp $HY2_PORT

# 节点 URI
if [[ "$NODE_MODE" == "1" ]]; then
VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp&flow=xtls-rprx-vision#VLESS-$DOMAIN"
HY2_URI="hysteria2://hy2user:$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=0&sni=$DOMAIN#HY2-$DOMAIN"
else
VLESS_URI="vless://$UUID@$VPS_IP:$VLESS_PORT?encryption=none&type=tcp#VLESS-$VPS_IP"
HY2_URI="hysteria2://hy2user:$HY2_PASS@$VPS_IP:$HY2_PORT?insecure=1#HY2-$VPS_IP"
fi

# QR 码
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png

# 输出
echo
echo "=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"

# 创建 rev 快捷显示脚本
cat > /root/show_singbox_nodes.sh <<EOF
#!/bin/bash
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo "刷新二维码..."
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"
EOF
chmod +x /root/show_singbox_nodes.sh
ln -sf /root/show_singbox_nodes.sh /usr/local/bin/rev
echo "快捷显示节点: 输入 rev"

# 卸载脚本
cat > ./uninstall_singbox.sh <<'EOF'
#!/bin/bash
systemctl stop sing-box
systemctl disable sing-box
rm -f /etc/sing-box/config.json
rm -f /root/vless_qr.png /root/hy2_qr.png
rm -f /root/show_singbox_nodes.sh
rm -f ./uninstall_singbox.sh
apt remove -y sing-box netcat-openbsd netcat-traditional qrencode socat curl openssl
echo "Sing-box 已卸载"
EOF
chmod +x ./uninstall_singbox.sh
echo "卸载: 输入 ./uninstall_singbox.sh"

echo "=================== 部署完成 ==================="

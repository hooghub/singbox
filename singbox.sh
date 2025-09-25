#!/bin/bash
# Sing-box 高级一键部署脚本 (VLESS + HY2 + 自动端口 + QR + Let's Encrypt)
# 支持无域名模式、rev 快捷显示节点、自动刷新二维码
# Author: ChatGPT

set -e

echo "=================== Sing-box 高级部署 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖，兼容所有 Debian/Ubuntu
apt update -y
apt install -y curl socat cron openssl qrencode lsof net-tools || apt install -y netcat-openbsd

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

# 选择节点模式
echo "请选择节点模式:"
echo "1) 有域名 (自动申请 TLS)"
echo "2) 无域名 (使用 VPS IP, 不启用 TLS)"
read -rp "请输入 1 或 2: " MODE

if [[ "$MODE" == "1" ]]; then
    read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " DOMAIN
    # 检查域名解析
    VPS_IP=$(curl -s ipv4.icanhazip.com)
    DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)
    if [[ "$DOMAIN_IP" != "$VPS_IP" ]]; then
        echo "[✖] 域名解析 ($DOMAIN_IP) 不指向当前 VPS ($VPS_IP)，请确认 DNS"
        exit 1
    fi
    USE_TLS=true
else
    VPS_IP=$(curl -s ipv4.icanhazip.com)
    DOMAIN="$VPS_IP"
    USE_TLS=false
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
VLESS_PORT=${VLESS_PORT:-0}
[[ "$VLESS_PORT" == "0" ]] && VLESS_PORT=$(get_random_port)

read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
HY2_PORT=${HY2_PORT:-0}
[[ "$HY2_PORT" == "0" ]] && HY2_PORT=$(get_random_port)

# UUID / HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# TLS 证书
CERT_DIR="/etc/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

if $USE_TLS; then
    echo ">>> 申请 Let's Encrypt TLS 证书"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
      --key-file       "$CERT_DIR/privkey.pem" \
      --fullchain-file "$CERT_DIR/fullchain.pem" --force
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
      "users": [{ "uuid": "$UUID" $(if $USE_TLS; then echo ', "flow": "xtls-rprx-vision"'; fi) }],
      $(if $USE_TLS; then echo '"tls": { "enabled": true, "server_name": "'"$DOMAIN"'", "certificate_path": "'"$CERT_DIR/fullchain.pem"'", "key_path": "'"$CERT_DIR/privkey.pem"'" }'; else echo '"tls": { "enabled": false }'; fi)
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      $(if $USE_TLS; then echo '"tls": { "enabled": true, "server_name": "'"$DOMAIN"'", "certificate_path": "'"$CERT_DIR/fullchain.pem"'", "key_path": "'"$CERT_DIR/privkey.pem"'" }'; else echo '"tls": { "enabled": false }'; fi)
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

# 启动 sing-box
systemctl enable sing-box
systemctl restart sing-box
sleep 2

# 检查端口监听
echo
echo "=================== 节点信息 ==================="
VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none$(if $USE_TLS; then echo "&security=tls&sni=$DOMAIN&type=tcp&flow=xtls-rprx-vision"; else echo "&type=tcp"; fi)#VLESS-$DOMAIN"
HY2_URI="hysteria2://hy2user:$HY2_PASS@$DOMAIN:$HY2_PORT?$(if $USE_TLS; then echo "insecure=0&sni=$DOMAIN"; else echo "insecure=1"; fi)#HY2-$DOMAIN"

echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"

# 生成二维码
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
echo -e "二维码文件:\n/root/vless_qr.png\n/root/hy2_qr.png"

# 端口自检 (TCP/UDP)
echo
echo "=================== 端口自检 ==================="
sleep 2
if nc -zv -w2 127.0.0.1 $VLESS_PORT &>/dev/null; then echo "[✔] VLESS TCP $VLESS_PORT 已监听"; else echo "[✖] VLESS TCP $VLESS_PORT 未监听"; fi
if nc -uvz -w2 127.0.0.1 $HY2_PORT &>/dev/null; then echo "[✔] HY2 UDP $HY2_PORT 已监听"; else echo "[✖] HY2 UDP $HY2_PORT 未监听"; fi

# 创建 rev 快捷别名
cat > /root/show_singbox_nodes.sh <<EOF
#!/bin/bash
echo -e "VLESS 节点:\\n$VLESS_URI"
echo -e "HY2 节点:\\n$HY2_URI"
echo -e "二维码文件:\\n/root/vless_qr.png\\n/root/hy2_qr.png"
EOF
chmod +x /root/show_singbox_nodes.sh
echo "快捷显示节点: 输入 rev"
echo "创建别名..."
grep -q 'alias rev=' ~/.bashrc || echo "alias rev='/root/show_singbox_nodes.sh'" >> ~/.bashrc
source ~/.bashrc

# 创建自动刷新二维码脚本
cat > /root/refresh_singbox_qr.sh <<EOF
#!/bin/bash
systemctl restart sing-box
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
echo "已刷新 sing-box 并重新生成二维码"
EOF
chmod +x /root/refresh_singbox_qr.sh

# 创建卸载快捷键
cat > /root/uninstall_singbox.sh <<EOF
#!/bin/bash
systemctl stop sing-box
systemctl disable sing-box
apt remove -y sing-box qrencode netcat-openbsd socat cron openssl curl
rm -rf /etc/sing-box /root/vless_qr.png /root/hy2_qr.png /root/show_singbox_nodes.sh /root/refresh_singbox_qr.sh
echo "Sing-box 已卸载完成"
EOF
chmod +x /root/uninstall_singbox.sh
echo "卸载: 输入 ./uninstall_singbox.sh"

echo
echo "=================== 部署完成 ==================="

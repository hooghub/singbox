#!/bin/bash
# Sing-box 高级一键部署脚本 (VLESS + HY2 + 自动端口 + QR/订阅 + Let's Encrypt)
# Author: ChatGPT

set -e

echo "=================== Sing-box 高级部署 (Let’s Encrypt) ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖
apt update -y
apt install -y curl socat cron openssl qrencode

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

# 用户输入域名
read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " DOMAIN

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
if [[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]]; then
    VLESS_PORT=$(get_random_port)
fi

# HY2 UDP 端口
read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
if [[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]]; then
    HY2_PORT=$(get_random_port)
fi

# UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# TLS 证书目录
CERT_DIR="/etc/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

echo ">>> 申请 Let's Encrypt TLS 证书"
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --key-file       "$CERT_DIR/privkey.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" --force

# 添加证书自动续签任务
(crontab -l 2>/dev/null; echo "0 3 * * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null && systemctl restart sing-box") | crontab -

# 生成 sing-box 配置
cat > /etc/sing-box/config.json <<EOF
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
      "users": [{ "name": "hy2user", "password": "$HY2_PASS" }],
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

# 启动 sing-box
systemctl enable sing-box
systemctl restart sing-box
sleep 3

# 检查端口监听
echo
[[ -n "$(ss -tulnp | grep $VLESS_PORT)" ]] && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
[[ -n "$(ss -ulnp | grep $HY2_PORT)" ]] && echo "[✔] HY2 UDP $HY2_PORT 已监听" || echo "[✖] HY2 UDP $HY2_PORT 未监听"

# 输出节点信息
VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp&flow=xtls-rprx-vision#VLESS-$DOMAIN"
HY2_URI="hysteria2://hy2user:$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=0&sni=$DOMAIN#HY2-$DOMAIN"

echo
echo "=================== 节点信息 ==================="
echo "VLESS 节点: $VLESS_URI"
echo "HY2 节点: $HY2_URI"

# 生成 QR 码文件
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
echo "QR 码已生成：/root/vless_qr.png 和 /root/hy2_qr.png"

# 生成订阅 JSON 文件
SUB_FILE="/root/singbox_nodes.json"
cat > $SUB_FILE <<EOF
{
  "vless": "$VLESS_URI",
  "hysteria2": "$HY2_URI"
}
EOF
echo "订阅文件生成：$SUB_FILE"

echo "=================== 部署完成 ==================="
echo "VLESS QR: /root/vless_qr.png"
echo "HY2 QR: /root/hy2_qr.png"
echo "订阅文件: $SUB_FILE"

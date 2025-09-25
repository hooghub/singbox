#!/bin/bash
# Sing-box 一键部署 VLESS + HY2 (TCP + UDP)
# Author: ChatGPT

set -e

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo "请使用 root 权限运行脚本"
   exit 1
fi

# 安装依赖
apt update -y && apt install -y curl socat cron openssl

# 安装 acme.sh
if ! command -v acme.sh &> /dev/null; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi

# 用户输入
read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " DOMAIN
read -rp "请输入 VLESS 端口 (默认443): " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-443}
read -rp "请输入 HY2 端口 (默认8443): " HY2_PORT
HY2_PORT=${HY2_PORT:-8443}

# 证书目录
CERT_DIR="/etc/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

# 检查证书是否存在
if [[ -f "$CERT_DIR/fullchain.pem" && -f "$CERT_DIR/privkey.pem" ]]; then
    echo "检测到已有证书，不重新申请"
else
    echo ">>> 申请证书 (Let’s Encrypt)"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --ecc \
        --key-file       "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem"
fi

# 安装 sing-box
if ! command -v sing-box &> /dev/null; then
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

# 随机生成 UUID 和 HY2 密码
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# 生成 sing-box 配置
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [
        { "uuid": "$VLESS_UUID", "flow": "xtls-rprx-vision" }
      ],
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
      "users": [
        { "name": "hy2user", "password": "$HY2_PASS" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      },
      "udp": true,
      "tcp": true
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

# 启动服务
systemctl enable sing-box
systemctl restart sing-box

# 输出节点信息
echo "===================================================="
echo "Sing-box 部署完成 ✅"
echo
echo "VLESS 节点："
echo "vless://$VLESS_UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp&flow=xtls-rprx-vision#VLESS-$DOMAIN"
echo
echo "HY2 节点："
echo "hysteria2://hy2user:$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=0&sni=$DOMAIN#HY2-$DOMAIN"
echo "===================================================="

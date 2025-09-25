#!/bin/bash
# Sing-box 高级一键部署脚本 (VLESS + HY2 + 自动端口 + QR显示 + Let's Encrypt + rev别名)
# Author: ChatGPT

set -e

show_nodes() {
    echo -e "\n=================== 节点信息 ==================="
    echo -e "VLESS 节点:\n$VLESS_URI"
    echo -e "HY2 节点:\n$HY2_URI"

    # 终端显示二维码
    echo -e "\nVLESS QR:"
    echo "$VLESS_URI" | qrencode -t ansiutf8
    echo -e "\nHY2 QR:"
    echo "$HY2_URI" | qrencode -t ansiutf8

    # 生成二维码文件
    echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
    echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
    echo -e "\n二维码文件已生成：/root/vless_qr.png 和 /root/hy2_qr.png"
}

echo "=================== Sing-box 高级部署 (Let’s Encrypt) ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖
apt update -y
apt install -y curl socat cron openssl qrencode dnsutils jq

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

# 检查域名解析是否指向当前 VPS
echo ">>> 检查域名解析..."
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)

if [[ -z "$DOMAIN_IP" ]]; then
    echo "[✖] 域名 $DOMAIN 未解析，请先正确配置 DNS"
    exit 1
fi

if [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
    echo "[✖] 域名 $DOMAIN 解析到 $DOMAIN_IP，但本机 IP 是 $SERVER_IP"
    echo "请先将域名解析到当前 VPS，再运行本脚本。"
    exit 1
fi

echo "[✔] 域名 $DOMAIN 已正确解析到当前 VPS ($SERVER_IP)"

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

# 添加证书自动续签任务（每30天执行一次）
(crontab -l 2>/dev/null | grep -v 'acme.sh'; echo "0 0 */30 * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null && systemctl restart sing-box") | crontab -

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
      "users": [{ "password": "$HY2_PASS" }],
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

# 保存节点信息到环境文件
VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp&flow=xtls-rprx-vision#VLESS-$DOMAIN"
HY2_URI="hysteria2://$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=0&sni=$DOMAIN#HY2-$DOMAIN"
cat > /root/singbox_nodes.env <<EOF
VLESS_URI="$VLESS_URI"
HY2_URI="$HY2_URI"
EOF

# 创建显示节点快捷脚本（增强版，显示终端二维码 + 生成二维码文件）
cat > /root/show_singbox_nodes.sh <<'EOF'
#!/bin/bash
source /root/singbox_nodes.env

echo -e "\n=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"

# 终端显示二维码
echo -e "\nVLESS QR:"
echo "$VLESS_URI" | qrencode -t ansiutf8
echo -e "\nHY2 QR:"
echo "$HY2_URI" | qrencode -t ansiutf8

# 生成二维码文件
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
echo -e "\n二维码文件已生成：/root/vless_qr.png 和 /root/hy2_qr.png"
EOF
chmod +x /root/show_singbox_nodes.sh

# 添加快捷别名 rev
if ! grep -q "alias rev=" ~/.bashrc; then
    echo "alias rev='/root/show_singbox_nodes.sh'" >> ~/.bashrc
    echo "快捷别名已添加：输入 rev 即可显示节点信息和二维码"
fi

# 启动 sing-box
systemctl enable sing-box
systemctl restart sing-box
sleep 3

# 检查端口监听
echo
[[ -n "$(ss -tulnp | grep $VLESS_PORT)" ]] && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
[[ -n "$(ss -ulnp | grep $HY2_PORT)" ]] && echo "[✔] HY2 UDP $HY2_PORT 已监听" || echo "[✖] HY2 UDP $HY2_PORT 未监听"

# 第一次显示节点信息
show_nodes

echo -e "\n部署完成！以后只需输入 rev 就可以显示节点信息和二维码。二维码文件也会自动生成。"

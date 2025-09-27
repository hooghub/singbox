```bash
#!/bin/bash
# Sing-box 高级一键部署脚本 (VLESS TCP+TLS + HY2 + 自动端口 + QR/订阅 + Let's Encrypt + 自动续签)
# Author: chis (优化 by ChatGPT)

set -e

echo "=================== Sing-box 高级部署 (Let’s Encrypt 优化版) ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖
apt update -y
apt install -y curl socat openssl qrencode dnsutils systemd

# 安装 acme.sh
if ! command -v acme.sh &>/dev/null; then
    echo ">>> 安装 acme.sh ..."
    curl https://get.acme.sh | sh
    source ~/.bashrc || true
fi

if [[ ! -f "/root/.acme.sh/acme.sh" ]]; then
    echo "[✖] acme.sh 安装失败，请手动执行: curl https://get.acme.sh | sh"
    exit 1
fi

# 设置默认 CA 为 Let's Encrypt
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    echo ">>> 安装 sing-box ..."
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

# 输入域名
read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " DOMAIN

# 检查域名是否解析到本机 IP
echo ">>> 检查域名解析..."
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)

if [[ -z "$DOMAIN_IP" ]]; then
    echo "[✖] 域名 $DOMAIN 未解析，请先正确配置 DNS"
    exit 1
fi
if [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
    echo "[✖] 域名 $DOMAIN 解析到 $DOMAIN_IP，但本机 IP 是 $SERVER_IP"
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
[[ -z "$VLESS_PORT" || "$VLESS_PORT" == "0" ]] && VLESS_PORT=$(get_random_port)

# HY2 UDP 端口
read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ -z "$HY2_PORT" || "$HY2_PORT" == "0" ]] && HY2_PORT=$(get_random_port)

# UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# TLS 证书目录
CERT_DIR="/etc/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

echo ">>> 申请 Let's Encrypt TLS 证书"
/root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --key-file "$CERT_DIR/privkey.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" --force

# 修复证书权限
chown -R nobody:nogroup "$CERT_DIR"
chmod 600 "$CERT_DIR"/*.pem

# systemd 自动续签
cat > /etc/systemd/system/acme-renew.service <<EOF
[Unit]
Description=Renew Let's Encrypt certificates via acme.sh

[Service]
Type=oneshot
ExecStart=/root/.acme.sh/acme.sh --cron --home /root/.acme.sh --force
ExecStartPost=/bin/systemctl restart sing-box
EOF

cat > /etc/systemd/system/acme-renew.timer <<EOF
[Unit]
Description=Run acme-renew.service daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now acme-renew.timer

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
      "decryption": "none",
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

# 启动 sing-box
systemctl enable sing-box
systemctl restart sing-box
sleep 3

# 检查端口监听
[[ -n "$(ss -tulnp | grep $VLESS_PORT)" ]] && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
[[ -n "$(ss -ulnp | grep $HY2_PORT)" ]] && echo "[✔] HY2 UDP $HY2_PORT 已监听" || echo "[✖] HY2 UDP $HY2_PORT 未监听"

# 输出节点信息
VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$DOMAIN"
HY2_URI="hysteria2://$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=0&sni=$DOMAIN#HY2-$DOMAIN"

echo -e "\n=================== VLESS 节点 ==================="
echo -e "$VLESS_URI\n"
echo "$VLESS_URI" | qrencode -t ansiutf8

echo -e "\n=================== HY2 节点 ==================="
echo -e "$HY2_URI\n"
echo "$HY2_URI" | qrencode -t ansiutf8

# 生成订阅 JSON
SUB_FILE="/root/singbox_nodes.json"
cat > $SUB_FILE <<EOF
{
  "vless": "$VLESS_URI",
  "hysteria2": "$HY2_URI"
}
EOF

echo -e "\n=================== 订阅文件内容 ==================="
cat $SUB_FILE
echo -e "\n订阅文件已保存到：$SUB_FILE"

echo -e "\n=================== 部署完成 ==================="
```

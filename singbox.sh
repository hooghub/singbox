#!/bin/bash
# Sing-box 高级静默部署脚本 (VLESS TCP+TLS + HY2 + UDP+TLS)
# Author: ChatGPT (优化)

set -e

echo "=================== Sing-box 完全静默部署 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖
apt-get update
apt-get install -y curl socat openssl qrencode dnsutils systemd lsof

# 安装 acme.sh
if ! command -v acme.sh &>/dev/null; then
    curl https://get.acme.sh | sh
fi
ACME_BIN="/root/.acme.sh/acme.sh"
[[ ! -f "$ACME_BIN" ]] && echo "[✖] acme.sh 安装失败" && exit 1

# 设置默认 CA
$ACME_BIN --set-default-ca --server letsencrypt

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    curl -fsSL -o /tmp/sing-box-install.sh https://sing-box.app/deb-install.sh
    bash /tmp/sing-box-install.sh
fi

# 获取公网 IP
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)

# 输入域名（静默模式可预设）
DOMAIN="${DOMAIN:-lg.lyn.edu.deal}"

# 检查域名解析
DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
[[ -z "$DOMAIN_IP" ]] && echo "[✖] 域名 $DOMAIN 未解析" && exit 1
[[ "$DOMAIN_IP" != "$SERVER_IP" ]] && echo "[✖] 域名解析 $DOMAIN_IP 不匹配 VPS $SERVER_IP" && exit 1
echo "[✔] 域名 $DOMAIN 已解析到 VPS $SERVER_IP"

# 随机端口函数
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        lsof -i:"$PORT" -sTCP:LISTEN &>/dev/null || break
    done
    echo $PORT
}

# 端口
VLESS_PORT="${VLESS_PORT:-$(get_random_port)}"
HY2_PORT="${HY2_PORT:-$(get_random_port)}"

# UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# TLS 证书目录
CERT_DIR="/etc/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

# 申请证书
$ACME_BIN --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
$ACME_BIN --install-cert -d "$DOMAIN" --ecc \
  --key-file "$CERT_DIR/privkey.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" --force

# 修复证书权限
chown -R root:root "$CERT_DIR"
chmod 600 "$CERT_DIR"/*.pem

# 创建 sing-box systemd 服务（如果不存在）
if [[ ! -f "/etc/systemd/system/sing-box.service" ]]; then
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable --now sing-box

# 自动续签 systemd timer
cat > /etc/systemd/system/acme-renew.service <<EOF
[Unit]
Description=Renew Let's Encrypt certificates via acme.sh
[Service]
Type=oneshot
ExecStart=$ACME_BIN --cron --home /root/.acme.sh --force
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
mkdir -p /etc/sing-box
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

# 重启服务
systemctl restart sing-box
sleep 3

# 输出节点
VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$DOMAIN"
HY2_URI="hysteria2://$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=0&sni=$DOMAIN#HY2-$DOMAIN"

echo -e "\n=================== 节点信息 ==================="
echo -e "$VLESS_URI\n$HY2_URI\n"
echo "$VLESS_URI" | qrencode -t ansiutf8
echo "$HY2_URI" | qrencode -t ansiutf8

# 订阅文件
SUB_FILE="/root/singbox_nodes.json"
cat > $SUB_FILE <<EOF
{
  "vless": "$VLESS_URI",
  "hysteria2": "$HY2_URI"
}
EOF

echo -e "\n订阅文件已保存到：$SUB_FILE"
echo -e "\n=================== 部署完成 ==================="

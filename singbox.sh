#!/bin/bash
# Sing-box 一键部署脚本 (VLESS TCP+TLS + HY2)
# 支持 模式选择 + 域名/自签 + 环境检查 + socat 前置依赖
# Author: ChatGPT

set -e

echo "=================== Sing-box 部署前环境检查 ==================="

# 1. 检查 root
if [[ $EUID -ne 0 ]]; then
    echo "[✖] 请用 root 权限运行"
    exit 1
else
    echo "[✔] Root 权限 OK"
fi

# 2. 获取公网 IP
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
if [[ -z "$SERVER_IP" ]]; then
    echo "[✖] 无法获取公网 IP，请检查网络"
    exit 1
else
    echo "[✔] 检测到公网 IP: $SERVER_IP"
fi

# 3. 检查必要命令
DEPS=("curl" "ss" "openssl" "qrencode" "dig" "systemctl" "bash" "socat")
for cmd in "${DEPS[@]}"; do
    if ! command -v $cmd &>/dev/null; then
        echo "[⚠] 缺少依赖: $cmd"
        MISSING_DEPS=true
    else
        echo "[✔] 命令存在: $cmd"
    fi
done

# 安装缺失依赖
if [[ "$MISSING_DEPS" == "true" ]]; then
    echo "[!] 安装缺失依赖..."
    apt update -y
    apt install -y curl iproute2 openssl qrencode dnsutils systemd socat
fi

# 4. 检查 80/443 端口占用
for PORT in 80 443; do
    if ss -tuln | grep -q ":$PORT "; then
        echo "[⚠] 端口 $PORT 已被占用，域名模式申请证书可能失败"
    else
        echo "[✔] 端口 $PORT 空闲"
    fi
done

echo -e "\n环境检查完成 ✅"
read -rp "确认继续执行部署吗？(y/N): " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && echo "已取消部署" && exit 0

# -------------------------------
# 安装 sing-box
# -------------------------------
if ! command -v sing-box &>/dev/null; then
    echo ">>> 安装 sing-box ..."
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

# -------------------------------
# 模式选择
# -------------------------------
echo -e "\n请选择部署模式："
echo "1) 使用域名 + Let's Encrypt 证书"
echo "2) 使用公网 IP + 自签证书"
read -rp "请输入选项 (1 或 2): " MODE

CERT_DIR="/etc/ssl/sing-box"
mkdir -p "$CERT_DIR"

if [[ "$MODE" == "1" ]]; then
    read -rp "请输入你的域名: " DOMAIN
    echo ">>> 检查域名解析..."
    DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
    if [[ -z "$DOMAIN_IP" ]]; then
        echo "[✖] 域名 $DOMAIN 未解析，请先配置 DNS"
        exit 1
    fi
    if [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
        echo "[✖] 域名 $DOMAIN 解析到 $DOMAIN_IP，但本机 IP 是 $SERVER_IP"
        exit 1
    fi
    echo "[✔] 域名 $DOMAIN 已正确解析到当前 VPS ($SERVER_IP)"

    # 安装 acme.sh
    if ! command -v acme.sh &>/dev/null; then
        echo ">>> 安装 acme.sh ..."
        curl https://get.acme.sh | sh
        source ~/.bashrc || true
    fi
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    echo ">>> 申请 Let's Encrypt TLS 证书"
    /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
      --key-file "$CERT_DIR/privkey.pem" \
      --fullchain-file "$CERT_DIR/fullchain.pem" --force

    # 自动续签
    cat > /etc/systemd/system/acme-renew.service <<EOF
[Unit]
Description=Renew Let's Encrypt certificates via acme.sh

[Service]
Type=oneshot
ExecStart=/root/.acme.sh/acme.sh --cron --home /root/.acme.sh --force
ExecStartPost=/bin/systemctl reload-or-restart sing-box
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

elif [[ "$MODE" == "2" ]]; then
    echo "[!] 使用公网 IP + 自签证书"
    DOMAIN=$SERVER_IP
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=$DOMAIN" \
        -keyout "$CERT_DIR/privkey.pem" \
        -out "$CERT_DIR/fullchain.pem"
else
    echo "[✖] 输入无效，请输入 1 或 2"
    exit 1
fi

# -------------------------------
# 随机端口函数
# -------------------------------
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# 输入端口
read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
[[ -z "$VLESS_PORT" || "$VLESS_PORT" == "0" ]] && VLESS_PORT=$(get_random_port)
read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ -z "$HY2_PORT" || "$HY2_PORT" == "0" ]] && HY2_PORT=$(get_random_port)

# UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# 修复证书权限
chmod 644 "$CERT_DIR"/*.pem

# -------------------------------
# 生成 sing-box 配置
# -------------------------------
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

# -------------------------------
# 启动 sing-box
# -------------------------------
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

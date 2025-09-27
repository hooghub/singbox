#!/bin/bash
# Sing-box 一键部署脚本 (VLESS TCP+TLS + Hysteria2)
# 支持：域名模式 / 自签模式
# Author: ChatGPT 改写，Hysteria2 默认 insecure=1

set -e

echo "=================== Sing-box 部署前环境检查 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "[✖] 请使用 root 运行" && exit 1

# 检查依赖
deps=(curl ss openssl qrencode dig systemctl bash socat)
for cmd in "${deps[@]}"; do
    if ! command -v $cmd &>/dev/null; then
        echo "[✖] 缺少命令: $cmd，请先安装"
        exit 1
    else
        echo "[✔] 命令存在: $cmd"
    fi
done

# 获取公网 IP
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
echo "[✔] 检测到公网 IP: $SERVER_IP"

# 检查端口 80/443 是否被占用
for PORT in 80 443; do
    if ss -tuln | grep -q ":$PORT "; then
        echo "[✖] 端口 $PORT 被占用，请释放"
        exit 1
    else
        echo "[✔] 端口 $PORT 空闲"
    fi
done

read -rp "环境检查完成 ✅ 确认继续执行部署吗？(y/N): " confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

# 选择模式
echo "请选择部署模式："
echo "1) 使用域名 + Let's Encrypt 证书"
echo "2) 使用公网 IP + 自签证书"
read -rp "请输入选项 (1 或 2): " MODE
[[ "$MODE" != "1" && "$MODE" != "2" ]] && echo "[✖] 输入错误" && exit 1

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    echo ">>> 安装 sing-box ..."
    curl -fsSL https://sing-box.app/deb-install.sh -o sing-box-install.sh
    bash sing-box-install.sh
fi

CERT_DIR="/etc/ssl/sing-box"
mkdir -p "$CERT_DIR"

if [[ "$MODE" == "1" ]]; then
    # 域名模式
    read -rp "请输入域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo "[✖] 域名不能为空" && exit 1

    DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
    if [[ -z "$DOMAIN_IP" ]]; then
        echo "[✖] 域名未解析"
        exit 1
    fi
    if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
        echo "[✖] 域名解析 $DOMAIN_IP 与 VPS IP $SERVER_IP 不符"
        exit 1
    fi
    echo "[✔] 域名解析正确"

    # 安装 acme.sh
    if ! command -v acme.sh &>/dev/null; then
        echo ">>> 安装 acme.sh ..."
        curl https://get.acme.sh | sh
        source ~/.bashrc || true
    fi

    # 使用已有证书优先
    if [[ -f "$CERT_DIR/privkey.pem" && -f "$CERT_DIR/fullchain.pem" ]]; then
        echo "[!] 检测到证书已存在，使用现有证书"
    else
        echo ">>> 申请 Let's Encrypt TLS 证书"
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
          --key-file "$CERT_DIR/privkey.pem" \
          --fullchain-file "$CERT_DIR/fullchain.pem" --force
    fi
else
    # 自签模式
    DOMAIN="$SERVER_IP"
    echo "[!] 使用自签证书 CN=$DOMAIN"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$CERT_DIR/privkey.pem" \
        -out "$CERT_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName = IP:$SERVER_IP"
    chmod 644 "$CERT_DIR"/*.pem
    echo "[✔] 自签证书生成成功"
fi

# 随机端口函数
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# 端口输入
read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
[[ -z "$VLESS_PORT" || "$VLESS_PORT" == "0" ]] && VLESS_PORT=$(get_random_port)
read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ -z "$HY2_PORT" || "$HY2_PORT" == "0" ]] && HY2_PORT=$(get_random_port)

# UUID/HY2 密码（Base64URL安全）
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12 | tr '+/' '_-' | tr -d '=')

# 生成 sing-box 配置
cat >/etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID" }],
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
HY2_URI="hysteria2://$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=1&sni=$DOMAIN#HY2-$DOMAIN"

echo -e "\n=================== VLESS 节点 ==================="
echo -e "$VLESS_URI\n"
echo "$VLESS_URI" | qrencode -t ansiutf8

echo -e "\n=================== HY2 节点 ==================="
echo -e "$HY2_URI\n"
echo "$HY2_URI" | qrencode -t ansiutf8
echo "[!] 注意：Hysteria2 使用 insecure=1，如果是自签证书，请在客户端允许 TLS 自签"

# 生成订阅 JSON
SUB_FILE="/root/singbox_nodes.json"
cat >$SUB_FILE <<EOF
{
  "vless": "$VLESS_URI",
  "hysteria2": "$HY2_URI"
}
EOF

echo -e "\n=================== 订阅文件 ==================="
cat $SUB_FILE
echo -e "\n订阅文件已保存到：$SUB_FILE"
echo -e "\n=================== 部署完成 ==================="

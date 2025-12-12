#!/bin/bash
# Sing-box 一键部署脚本 (最终增强版)
# 支持：域名模式 / 自签固定域名 www.epple.com (URI 使用公网 IP)
# Author: Chis (优化 by ChatGPT)

set -e

echo "=================== Sing-box 部署前环境检查 ==================="

# --------- 检查 root ---------
[[ $EUID -ne 0 ]] && echo "[✖] 请用 root 权限运行" && exit 1 || echo "[✔] Root 权限 OK"

# --------- 检测公网 IP ---------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[[ -n "$SERVER_IP" ]] && echo "[✔] 检测到公网 IP: $SERVER_IP" || { echo "[✖] 获取公网 IP 失败"; exit 1; }

# --------- 自动安装依赖 ---------
REQUIRED_CMDS=(curl ss openssl qrencode dig systemctl bash socat ufw)
MISSING_CMDS=()
for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v $cmd >/dev/null 2>&1 || MISSING_CMDS+=("$cmd")
done

if [[ ${#MISSING_CMDS[@]} -gt 0 ]]; then
    echo "[!] 检测到缺失命令: ${MISSING_CMDS[*]}"
    echo "[!] 自动安装依赖中..."
    apt update -y
    INSTALL_PACKAGES=()
    for cmd in "${MISSING_CMDS[@]}"; do
        case "$cmd" in
            dig) INSTALL_PACKAGES+=("dnsutils") ;;
            qrencode|socat|ufw) INSTALL_PACKAGES+=("$cmd") ;;
            *) INSTALL_PACKAGES+=("$cmd") ;;
        esac
    done
    apt install -y "${INSTALL_PACKAGES[@]}"
fi

# --------- 检查常用端口 ---------
for port in 80 443; do
    if ss -tuln | grep -q ":$port"; then
        echo "[✖] 端口 $port 已被占用"
    else
        echo "[✔] 端口 $port 空闲"
    fi
done

read -rp "环境检查完成 ✅\n确认继续执行部署吗？(y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

# --------- 模式选择 ---------
echo -e "\n请选择部署模式：\n1) 使用域名 + Let's Encrypt 证书\n2) 使用公网 IP + 自签固定域名 www.epple.com"
read -rp "请输入选项 (1 或 2): " MODE
[[ "$MODE" =~ ^[12]$ ]] || { echo "[✖] 输入错误"; exit 1; }

# --------- 安装 sing-box ---------
if ! command -v sing-box &>/dev/null; then
    echo ">>> 安装 sing-box ..."
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

CERT_DIR="/etc/ssl/sing-box"
mkdir -p "$CERT_DIR"

# --------- 域名模式 ---------
if [[ "$MODE" == "1" ]]; then
    read -rp "请输入你的域名 (例如: example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && { echo "[✖] 域名不能为空"; exit 1; }

    DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
    [[ -z "$DOMAIN_IP" ]] && { echo "[✖] 域名未解析"; exit 1; }
    [[ "$DOMAIN_IP" != "$SERVER_IP" ]] && { echo "[✖] 域名解析 $DOMAIN_IP 与 VPS IP $SERVER_IP 不符"; exit 1; }
    echo "[✔] 域名解析正常"

    # 安装 acme.sh
    if ! command -v acme.sh &>/dev/null; then
        echo ">>> 安装 acme.sh ..."
        curl https://get.acme.sh | sh
        source ~/.bashrc || true
    fi
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    # 检查现有证书
    LE_CERT_PATH="$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    LE_KEY_PATH="$HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key"
    if [[ -f "$LE_CERT_PATH" && -f "$LE_KEY_PATH" ]]; then
        echo "[✔] 已检测到现有 Let’s Encrypt 证书，直接导入"
        cp "$LE_CERT_PATH" "$CERT_DIR/fullchain.pem"
        cp "$LE_KEY_PATH" "$CERT_DIR/privkey.pem"
        chmod 644 "$CERT_DIR"/*.pem
    else
        echo ">>> 申请新的 Let's Encrypt TLS 证书"
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --key-file "$CERT_DIR/privkey.pem" \
            --fullchain-file "$CERT_DIR/fullchain.pem" --force
    fi
else
    # --------- 自签固定域名模式 ---------
    DOMAIN="www.epple.com"
    echo "[!] 自签模式，将生成固定域名 $DOMAIN 的自签证书 (URI 使用 VPS 公网 IP)"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$CERT_DIR/privkey.pem" \
        -out "$CERT_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
    chmod 644 "$CERT_DIR"/*.pem
    echo "[✔] 自签证书生成完成，CN/SAN 包含 $DOMAIN 和 $SERVER_IP"
fi

# --------- 随机端口函数 ---------
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# --------- 输入端口 ---------
read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
[[ -z "$VLESS_PORT" || "$VLESS_PORT" == "0" ]] && VLESS_PORT=$(get_random_port)
read -rp "请输入 Hysteria2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ -z "$HY2_PORT" || "$HY2_PORT" == "0" ]] && HY2_PORT=$(get_random_port)

# --------- 自动生成 UUID 和 HY2 密码 ---------
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')

# --------- 生成 sing-box 配置 ---------
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": ":",
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
      "listen": ":",
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

# --------- 防火墙端口开放（仅检测到 UFW 时） ---------
if command -v ufw &>/dev/null; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow "$VLESS_PORT"/tcp
    ufw allow "$HY2_PORT"/udp
    ufw reload || true
fi

# --------- 启动 sing-box ---------
systemctl enable sing-box
systemctl restart sing-box
sleep 3

# --------- 检查端口监听 ---------
[[ -n "$(ss -tulnp | grep $VLESS_PORT)" ]] && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
[[ -n "$(ss -ulnp | grep $HY2_PORT)" ]] && echo "[✔] Hysteria2 UDP $HY2_PORT 已监听" || echo "[✖] Hysteria2 UDP $HY2_PORT 未监听"

# --------- 生成节点 URI 和二维码 ---------
if [[ "$MODE" == "1" ]]; then
    NODE_HOST="$DOMAIN"
    INSECURE="0"
else
    NODE_HOST="$SERVER_IP"
    INSECURE="1"
fi

VLESS_URI="vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
HY2_URI="hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$INSECURE&sni=$DOMAIN#HY2-$NODE_HOST"

echo -e "\n=================== VLESS 节点 ==================="
echo -e "$VLESS_URI\n"
command -v qrencode &>/dev/null && echo "$VLESS_URI" | qrencode -t ansiutf8

echo -e "\n=================== Hysteria2 节点 ==================="
echo -e "$HY2_URI\n"
command -v qrencode &>/dev/null && echo "$HY2_URI" | qrencode -t ansiutf8

# --------- 生成订阅 JSON ---------
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

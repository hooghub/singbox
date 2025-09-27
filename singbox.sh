#!/bin/bash
# Sing-box 一键部署脚本 (VLESS TCP+TLS + Hysteria2)
# 支持：域名模式(LE证书) / 自签模式(CN=www.epple.com + SAN包含IP)
# VLESS/Hysteria2 URI 自动使用公网 IP，客户端直接可用
# Author: ChatGPT 改写

set -e

echo "=================== Sing-box 部署前环境检查 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "[✖] 请使用 root 权限运行" && exit 1 || echo "[✔] Root 权限 OK"

# 公网 IP
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
echo "[✔] 检测到公网 IP: $SERVER_IP"

# 检查必要命令
for cmd in curl ss openssl qrencode dig systemctl bash socat ufw; do
    command -v $cmd >/dev/null 2>&1 && echo "[✔] 命令存在: $cmd" || { echo "[✖] 缺少命令: $cmd, 请先安装"; exit 1; }
done

# 检查端口
for port in 80 443; do
    if ss -tuln | grep -q ":$port "; then
        echo "[✖] 端口 $port 已被占用"
        exit 1
    else
        echo "[✔] 端口 $port 空闲"
    fi
done

read -rp "环境检查完成 ✅\n确认继续执行部署吗？(y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

# 模式选择
echo "请选择部署模式："
echo "1) 使用域名 + Let's Encrypt 证书"
echo "2) 使用公网 IP + 自签固定域名 www.epple.com"
read -rp "请输入选项 (1 或 2): " MODE
[[ "$MODE" != "1" && "$MODE" != "2" ]] && echo "[✖] 选项错误" && exit 1

CERT_DIR="/etc/ssl/sing-box"
mkdir -p "$CERT_DIR"

if [[ "$MODE" == "1" ]]; then
    # 域名模式
    read -rp "请输入你的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo "[✖] 域名不能为空" && exit 1

    echo ">>> 检查域名解析..."
    DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
    if [[ -z "$DOMAIN_IP" ]]; then
        echo "[✖] 域名 $DOMAIN 未解析"
        exit 1
    fi
    if [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
        echo "[✖] 域名 $DOMAIN 解析到 $DOMAIN_IP，但本机 IP 是 $SERVER_IP"
        exit 1
    fi
    echo "[✔] 域名解析正确"

    # 安装 acme.sh
    if ! command -v acme.sh &>/dev/null; then
        echo ">>> 安装 acme.sh ..."
        curl https://get.acme.sh | sh
        source ~/.bashrc || true
    fi

    # 使用已有证书则不重复申请
    if [[ -f "$CERT_DIR/privkey.pem" && -f "$CERT_DIR/fullchain.pem" ]]; then
        echo "[✔] 已存在证书，跳过申请"
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
    echo "[!] 自签模式，将生成固定域名 www.epple.com 的自签证书"
    CN_DOMAIN="www.epple.com"

    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
        -subj "/CN=$CN_DOMAIN" \
        -addext "subjectAltName=DNS:$CN_DOMAIN,IP:$SERVER_IP" \
        -keyout "$CERT_DIR/privkey.pem" \
        -out "$CERT_DIR/fullchain.pem"

    echo "[✔] 自签证书生成完成，CN 和 SAN 包含 www.epple.com + $SERVER_IP"
    echo "[!] 客户端连接请允许自签证书 (Hysteria2 insecure=1)"
    DOMAIN="$SERVER_IP"
fi

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    echo ">>> 安装 sing-box ..."
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

# 随机端口函数
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q ":$PORT " || break
    done
    echo $PORT
}

# 输入端口
read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
[[ -z "$VLESS_PORT" || "$VLESS_PORT" == "0" ]] && VLESS_PORT=$(get_random_port)
read -rp "请输入 Hysteria2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ -z "$HY2_PORT" || "$HY2_PORT" == "0" ]] && HY2_PORT=$(get_random_port)

# UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 16 | tr -d '/+=')

# 防火墙放行
for p in 80 443 $VLESS_PORT $HY2_PORT; do
    ufw allow $p >/dev/null 2>&1 || echo "[!] 无法放行端口 $p"
done

# 修复证书权限
chmod 644 "$CERT_DIR"/*.pem

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
        "server_name": "$CN_DOMAIN"
      },
      "certificate": {
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
        "server_name": "$CN_DOMAIN"
      },
      "certificate": {
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
[[ -n "$(ss -tulnp | grep ":$VLESS_PORT ")" ]] && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
[[ -n "$(ss -ulnp | grep ":$HY2_PORT ")" ]] && echo "[✔] Hysteria2 UDP $HY2_PORT 已监听" || echo "[✖] Hysteria2 UDP $HY2_PORT 未监听"

# 输出节点信息
VLESS_URI="vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&security=tls&sni=$CN_DOMAIN&type=tcp#VLESS-$SERVER_IP"
HY2_URI="hysteria2://$HY2_PASS@$SERVER_IP:$HY2_PORT?insecure=1&sni=$CN_DOMAIN#HY2-$SERVER_IP"

echo -e "\n=================== VLESS 节点 ==================="
echo -e "$VLESS_URI\n"
echo "$VLESS_URI" | qrencode -t ansiutf8

echo -e "\n=================== Hysteria2 节点 ==================="
echo -e "$HY2_URI\n"
echo "$HY2_URI" | qrencode -t ansiutf8

# 生成订阅 JSON
SUB_FILE="/root/singbox_nodes.json"
cat >$SUB_FILE <<EOF
{
  "vless": "$VLESS_URI",
  "hysteria2": "$HY2_URI"
}
EOF

echo -e "\n=================== 订阅文件内容 ==================="
cat $SUB_FILE
echo -e "\n订阅文件已保存到：$SUB_FILE"

echo -e "\n=================== 部署完成 ==================="

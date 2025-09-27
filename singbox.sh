#!/bin/bash
# Sing-box 一键部署脚本 (VLESS TCP+TLS + HY2)
# 支持模式选择 + 域名/自签 + 最新 sing-box 配置
# Author: ChatGPT 改写版 2025

set -e

echo "=================== Sing-box 部署前环境检查 ==================="

# -------------------------------
# 1. 检查 root
# -------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[✖] 请用 root 权限运行"
    exit 1
else
    echo "[✔] Root 权限 OK"
fi

# -------------------------------
# 2. 获取公网 IP
# -------------------------------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
if [[ -z "$SERVER_IP" ]]; then
    echo "[✖] 无法获取公网 IP，请检查网络"
    exit 1
else
    echo "[✔] 检测到公网 IP: $SERVER_IP"
fi

# -------------------------------
# 3. 检查必要命令
# -------------------------------
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

# -------------------------------
# 4. 检查 80/443 端口占用
# -------------------------------
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
ExecStartPost=/

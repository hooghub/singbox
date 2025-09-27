#!/bin/bash
# Sing-box 一键部署脚本 (最终整合版)
# 支持：域名模式 / 自签固定域名 www.epple.com
# Author: Chis (优化 by ChatGPT)

set -e

echo "=================== Sing-box 部署前环境检查 ==================="

# --------- 检查 root ---------
[[ $EUID -ne 0 ]] && echo "[✖] 请用 root 权限运行" && exit 1 || echo "[✔] Root 权限 OK"

# --------- 检测 VPS 公网 IP ---------
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

# --------- 端口检查 ---------
for port in 80 443; do
    if ss -tuln | grep -q ":$port"; then
        echo "[✖] 端口 $port 已被占用"; exit 1
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
            --key-file "$CERT_DIR/privkey.pem"_

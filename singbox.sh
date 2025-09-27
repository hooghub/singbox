#!/bin/bash
# Sing-box 一键部署/升级/卸载脚本 (最终整合版)
# Author: Chis (优化 by ChatGPT)
set -e

CERT_DIR="/etc/ssl/sing-box"

# -------------------- 工具函数 --------------------
check_root() {
    [[ $EUID -ne 0 ]] && echo "[✖] 请用 root 权限运行" && exit 1 || echo "[✔] Root 权限 OK"
}

get_server_ip() {
    SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
    [[ -n "$SERVER_IP" ]] && echo "[✔] 检测到公网 IP: $SERVER_IP" || { echo "[✖] 获取公网 IP 失败"; exit 1; }
}

install_deps() {
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
}

check_ports() {
    for port in 80 443; do
        if ss -tuln | grep -q ":$port"; then
            echo "[✖] 端口 $port 已被占用"; exit 1
        else
            echo "[✔] 端口 $port 空闲"
        fi
    done
}

get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# -------------------- 部署 --------------------
deploy_singbox() {
    echo "=================== Sing-box 部署 ==================="
    mkdir -p "$CERT_DIR"

    read -rp "请选择部署模式：1) 域名 + LE证书  2) 公网 IP + 自签固定域名 www.epple.com : " MODE
    [[ "$MODE" =~ ^[12]$ ]] || { echo "[✖] 输入错误"; exit 1; }

    # 安装 sing-box
    if ! command -v sing-box &>/dev/null; then
        echo ">>> 安装 sing-box ..."
        bash <(curl -fsSL https://sing-box.app/deb-install.sh)
    fi

    # -------------------- 域名模式 --------------------
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
        VLESS_INSECURE=0

    # -------------------- 自签模式 --------------------
    else
        DOMAIN="www.epple.com"
        echo "[!] 自签模式，将生成固定域名 $DOMAIN 的自签证书 (URI 使用 VPS 公网 IP)"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
        chmod 644 "$CERT_DIR"/*.pem
        echo "[✔] 自签证书生成完成，CN/SAN 包含 $DOMAIN 和 $SERVER_IP"
        VLESS_INSECURE=1
    fi

    # -------------------- 输入端口 --------------------
    read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
    [[ -z "$VLESS_PORT" || "$VLESS_PORT" == "0" ]] && VLESS_PORT=$(get_random_port)
    read -rp "请输入 Hysteria2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
    [[ -z "$HY2_PORT" || "$HY2_PORT" == "0" ]] && HY2_PORT=$(get_random_port)

    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')

    # -------------------- 生成配置 --------------------
    cat > /etc/sing-box/config.json <<EOF
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

    # -------------------- 开放端口 --------------------
    if command -v ufw &>/dev/null; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow "$VLESS_PORT"/tcp
        ufw allow "$HY2_PORT"/udp
        ufw reload || true
    fi

    # -------------------- 启动服务 --------------------
    systemctl enable sing-box
    systemctl restart sing-box
    sleep 3

    [[ -n "$(ss -tulnp | grep $VLESS_PORT)" ]] && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
    [[ -n "$(ss -ulnp | grep $HY2_PORT)" ]] && echo "[✔] Hysteria2 UDP $HY2_PORT 已监听" || echo "[✖] Hysteria2 UDP $HY2_PORT 未监听"

    # -------------------- 节点信息与二维码 --------------------
    VLESS_URI="vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp&insecure=$VLESS_INSECURE#VLESS-$DOMAIN"
    HY2_URI="hysteria2://$HY2_PASS@$SERVER_IP:$HY2_PORT?insecure=1&sni=$DOMAIN#HY2-$DOMAIN"

    echo -e "\n=================== VLESS 节点 ==================="
    echo -e "$VLESS_URI\n"
    command -v qrencode &>/dev/null && echo "$VLESS_URI" | qrencode -t ansiutf8

    echo -e "\n=================== Hysteria2 节点 ==================="
    echo -e "$HY2_URI\n"
    command -v qrencode &>/dev/null && echo "$HY2_URI" | qrencode -t ansiutf8

    echo -e "\n=================== 部署完成 ==================="
}

# -------------------- 升级 --------------------
upgrade_singbox() {
    echo "=================== 升级 Sing-box ==================="
    systemctl stop sing-box || true
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
    systemctl restart sing-box
    echo "[✔] 升级完成"
}

# -------------------- 卸载 --------------------
uninstall_singbox() {
    echo "=================== 卸载 Sing-box ==================="
    systemctl stop sing-box || true
    systemctl disable sing-box || true
    rm -f /usr/local/bin/sing-box /etc/systemd/system/sing-box.service
    rm -rf /etc/sing-box /etc/ssl/sing-box
    echo "[✔] 卸载完成"
}

# -------------------- 主菜单 --------------------
main_menu() {
    echo -e "\nSing-box 一键管理脚本"
    echo "1) 部署 Sing-box"
    echo "2) 升级 Sing-box"
    echo "3) 卸载 Sing-box"
    echo "0) 退出"
    read -rp "请选择操作: " CHOICE
    case "$CHOICE" in
        1) check_root; get_server_ip; install_deps; check_ports; deploy_singbox ;;
        2) check_root; upgrade_singbox ;;
        3) check_root; uninstall_singbox ;;
        0) exit 0 ;;
        *) echo "[✖] 输入错误"; exit 1 ;;
    esac
}

main_menu

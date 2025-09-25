#!/bin/bash
# Sing-box 高级部署脚本 (VLESS + HY2 + 自动端口 + QR + Let's Encrypt / 无域名 + rev + 卸载)
# Author: ChatGPT

set -e

echo "=================== Sing-box 高级部署 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖，兼容所有 Debian/Ubuntu 版本
apt update -y
apt install -y curl socat cron openssl qrencode lsof net-tools

# 安装 netcat
if ! command -v nc &>/dev/null; then
    if apt-cache show netcat-openbsd &>/dev/null; then
        apt install -y netcat-openbsd
    else
        apt install -y netcat-traditional
    fi
fi

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

# 用户选择模式
echo "请选择节点模式:"
echo "1) 有域名 (自动申请 TLS)"
echo "2) 无域名 (使用 VPS IP, 不启用 TLS)"
read -rp "请输入 1 或 2: " NODE_MODE

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
[[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]] && VLESS_PORT=$(get_random_port)
read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]] && HY2_PORT=$(get_random_port)

# UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# 域名模式
if [[ "$NODE_MODE" == "1" ]]; then
    read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " DOMAIN

    # 检查域名是否解析到本机 IP
    VPS_IP=$(curl -s ipv4.icanhazip.com)
    DOMAIN_IP=$(dig +short $DOMAIN)
    if [[ "$DOMAIN_IP" != "$VPS_IP" ]]; then
        echo "⚠️ 域名 $DOMAIN 未指向当前 VPS IP ($VPS_IP)，acme.sh 可能会失败。"
        read -rp "是否继续？(y/n): " CONT
        [[ "$CONT" != "y" ]] && exit 1
    fi

    # TLS 证书目录
    CERT_DIR="/etc/ssl/$DOMAIN"
    mkdir -p "$CERT_DIR"

    echo ">>> 申请 Let's Encrypt TLS 证书"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file       "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" --force
    TLS_ENABLED="true"
else
    # 无域名模式使用 VPS IP
    DOMAIN=$(curl -s ipv4.icanhazip.com)
    TLS_ENABLED="false"
fi

# 生成 sing-box 配置
CONFIG_FILE="/etc/sing-box/config.json"
mkdir -p /etc/sing-box

cat > $CONFIG_FILE <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID" }]$( [[ "$NODE_MODE" == "1" ]] && echo ', "flow":"xtls-rprx-vision"' || echo '')$([[ "$TLS_ENABLED" == "true" ]] && echo ',
      "tls": {
        "enabled": true,
        "server_name": "'"$DOMAIN"'",
        "certificate_path": "'"$CERT_DIR/fullchain.pem"'",
        "key_path": "'"$CERT_DIR/privkey.pem"'"
      }' || echo '')
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }]$([[ "$TLS_ENABLED" == "true" ]] && echo ',
      "tls": {
        "enabled": true,
        "server_name": "'"$DOMAIN"'",
        "certificate_path": "'"$CERT_DIR/fullchain.pem"'",
        "key_path": "'"$CERT_DIR/privkey.pem"'"
      }' || echo '')
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

# 启动 sing-box
systemctl enable sing-box
systemctl restart sing-box
sleep 3

# 端口自检函数
check_port() {
    local type=$1 port=$2
    if [[ "$type" == "tcp" ]]; then
        nc -zv 127.0.0.1 $port &>/dev/null && echo "[✔] VLESS TCP $port 已监听" || echo "[✖] VLESS TCP $port 未监听"
    else
        timeout 1 bash -c "echo > /dev/udp/127.0.0.1/$port" &>/dev/null && echo "[✔] HY2 UDP $port 已监听" || echo "[✖] HY2 UDP $port 未监听"
    fi
}

# 输出节点信息
VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none$( [[ "$NODE_MODE" == "1" ]] && echo "&security=tls&sni=$DOMAIN&type=tcp&flow=xtls-rprx-vision" )#VLESS-$DOMAIN"
HY2_URI="hysteria2://$HY2_PASS@$DOMAIN:$HY2_PORT$( [[ "$NODE_MODE" == "1" ]] && echo "?insecure=0&sni=$DOMAIN" )#HY2-$DOMAIN"

echo
echo "=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"

# 生成二维码
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
echo -e "二维码文件:\n/root/vless_qr.png\n/root/hy2_qr.png"

# 端口自检
echo
echo "=================== 端口自检 ==================="
check_port tcp $VLESS_PORT
check_port udp $HY2_PORT

# 创建 rev 快捷别名
cat > /root/show_singbox_nodes.sh <<EOF
#!/bin/bash
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo -e "二维码文件:\n/root/vless_qr.png\n/root/hy2_qr.png"
EOF
chmod +x /root/show_singbox_nodes.sh
if ! grep -q "alias rev=" ~/.bashrc; then
    echo "alias rev='/root/show_singbox_nodes.sh'" >> ~/.bashrc
fi

# 卸载快捷方式
cat > /root/uninstall_singbox.sh <<'EOF'
#!/bin/bash
systemctl stop sing-box
systemctl disable sing-box
rm -f /etc/sing-box/config.json
rm -f /root/vless_qr.png /root/hy2_qr.png
rm -f /root/show_singbox_nodes.sh /root/uninstall_singbox.sh
apt remove -y sing-box
echo "Sing-box 已卸载"
EOF
chmod +x /root/uninstall_singbox.sh

echo
echo "=================== 部署完成 ==================="
echo -e "VLESS QR: /root/vless_qr.png"
echo -e "HY2 QR: /root/hy2_qr.png"
echo -e "快捷显示节点: 输入 rev"
echo -e "卸载: 输入 ./uninstall_singbox.sh"

# 自动刷新二维码功能（可选，每次重启 sing-box 后运行）
# systemctl restart sing-box && bash /root/show_singbox_nodes.sh

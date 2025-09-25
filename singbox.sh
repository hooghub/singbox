#!/bin/bash
# Sing-box 高级一键部署脚本 (VLESS + HY2 + 自动端口 + QR + Let's Encrypt)
# Author: Chis

set -e

echo "=================== Sing-box 高级部署 (Let’s Encrypt) ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖
apt update -y
apt install -y curl socat cron openssl qrencode

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

# 用户选择是否有域名
echo "请选择节点类型："
echo "1) 有域名（使用 Let's Encrypt 证书）"
echo "2) 无域名（仅生成节点，不启用 TLS）"
read -rp "请输入 1 或 2: " NODE_TYPE

if [[ "$NODE_TYPE" == "1" ]]; then
    USE_TLS=true
    read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " DOMAIN

    # 检查域名解析是否指向本 VPS
    VPS_IP=$(curl -s https://ipinfo.io/ip)
    DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)
    if [[ "$DOMAIN_IP" != "$VPS_IP" ]]; then
        echo "错误：域名 $DOMAIN 没有解析到当前 VPS ($VPS_IP)，acme.sh 可能申请失败"
        exit 1
    fi

    CERT_DIR="/etc/ssl/$DOMAIN"
    mkdir -p "$CERT_DIR"

    echo ">>> 申请 Let's Encrypt TLS 证书"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file       "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" --force

    # TLS 配置
    VLESS_TLS_CONFIG="\"tls\": { \"enabled\": true, \"server_name\": \"$DOMAIN\", \"certificate_path\": \"$CERT_DIR/fullchain.pem\", \"key_path\": \"$CERT_DIR/privkey.pem\" }"
    HY2_TLS_CONFIG="\"tls\": { \"enabled\": true, \"server_name\": \"$DOMAIN\", \"certificate_path\": \"$CERT_DIR/fullchain.pem\", \"key_path\": \"$CERT_DIR/privkey.pem\" }"

    # 添加证书自动续签任务，每30天
    (crontab -l 2>/dev/null; echo "0 3 */30 * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null && systemctl restart sing-box") | crontab -

else
    USE_TLS=false
    VLESS_TLS_CONFIG="\"tls\": { \"enabled\": false }"
    HY2_TLS_CONFIG="\"tls\": { \"enabled\": false }"
fi

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
[[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]] && VLESS_PORT=$(get_random_port)

# HY2 UDP 端口
read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]] && HY2_PORT=$(get_random_port)

# UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# 生成 sing-box 配置
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      $VLESS_TLS_CONFIG
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      $HY2_TLS_CONFIG
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
echo
[[ -n "$(ss -tulnp | grep $VLESS_PORT)" ]] && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
[[ -n "$(ss -ulnp | grep $HY2_PORT)" ]] && echo "[✔] HY2 UDP $HY2_PORT 已监听" || echo "[✖] HY2 UDP $HY2_PORT 未监听"

# 输出节点信息并生成二维码
VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp&flow=xtls-rprx-vision#VLESS-$DOMAIN"
HY2_URI="hysteria2://hy2user:$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=0&sni=$DOMAIN#HY2-$DOMAIN"

echo -e "\n=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"

echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
echo -e "二维码已生成:\n/root/vless_qr.png\n/root/hy2_qr.png"

# 创建 rev 快捷方式
cat > /root/show_singbox_nodes.sh <<'EOS'
#!/bin/bash
# 显示节点信息并重新生成二维码
CONFIG_FILE="/etc/sing-box/config.json"
VLESS_URI=$(jq -r '.inbounds[0].users[0].uuid' $CONFIG_FILE | xargs -I{} echo "vless://{}@'"$DOMAIN"':'"$VLESS_PORT"'?encryption=none&security=tls&sni='"$DOMAIN"'&type=tcp&flow=xtls-rprx-vision#VLESS-'"$DOMAIN"'")
HY2_URI=$(jq -r '.inbounds[1].users[0].password' $CONFIG_FILE | xargs -I{} echo "hysteria2://hy2user:{}@'"$DOMAIN"':'"$HY2_PORT"'?insecure=0&sni='"$DOMAIN"'#HY2-'"$DOMAIN"'")
echo -e "\n=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
echo -e "二维码已更新:\n/root/vless_qr.png\n/root/hy2_qr.png"
EOS

chmod +x /root/show_singbox_nodes.sh
echo "alias rev='/root/show_singbox_nodes.sh'" >> /etc/profile
source /etc/profile

# 卸载快捷键
cat > /root/uninstall_singbox.sh <<'EOS'
#!/bin/bash
systemctl stop sing-box
systemctl disable sing-box
rm -f /etc/sing-box/config.json
rm -f /root/show_singbox_nodes.sh
rm -f /root/uninstall_singbox.sh
rm -f /root/vless_qr.png /root/hy2_qr.png
echo "Sing-box 已卸载完成"
EOS
chmod +x /root/uninstall_singbox.sh
echo "卸载快捷方式: uninstall_singbox.sh"

echo -e "\n=================== 部署完成 ==================="
echo -e "VLESS QR: /root/vless_qr.png"
echo -e "HY2 QR: /root/hy2_qr.png"
echo "快捷显示节点: 输入 rev"
echo "卸载: 输入 ./uninstall_singbox.sh"

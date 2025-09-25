#!/bin/bash
# Sing-box 高级部署脚本 (VLESS + HY2 + 自动端口 + QR + Let's Encrypt)
# Author: ChatGPT

set -e

echo "=================== Sing-box 高级部署 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖（兼容 Debian/Ubuntu 所有版本）
apt update -y
apt install -y curl socat cron openssl qrencode netcat-openbsd || apt install -y netcat-traditional || true

# 安装 acme.sh
if ! command -v acme.sh &>/dev/null; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi
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

USE_TLS=0
if [[ "$NODE_MODE" == "1" ]]; then
    read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " DOMAIN
    USE_TLS=1

    # 检测域名是否指向本 VPS
    VPS_IP=$(curl -s https://ip.gs)
    DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)
    if [[ "$DOMAIN_IP" != "$VPS_IP" ]]; then
        echo "域名解析($DOMAIN_IP)与 VPS IP($VPS_IP)不一致，无法申请证书"
        exit 1
    fi

    # 申请 TLS
    CERT_DIR="/etc/ssl/$DOMAIN"
    mkdir -p "$CERT_DIR"
    echo ">>> 申请 Let's Encrypt TLS 证书"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
      --key-file       "$CERT_DIR/privkey.pem" \
      --fullchain-file "$CERT_DIR/fullchain.pem" --force

    # 自动续签每 30 天
    (crontab -l 2>/dev/null; echo "0 3 */30 * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null && systemctl restart sing-box") | crontab -
else
    # 无域名模式
    VPS_IP=$(curl -s https://ip.gs)
    DOMAIN="$VPS_IP"
    CERT_DIR=""
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
      "users": [{ "uuid": "$UUID", "flow": "$( [[ $USE_TLS -eq 1 ]] && echo "xtls-rprx-vision" || echo "" )" }],
      "tls": {
        "enabled": $( [[ $USE_TLS -eq 1 ]] && echo "true" || echo "false" ),
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
      "tls": { "enabled": false }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

# 启动 sing-box
systemctl enable sing-box
systemctl restart sing-box
sleep 5  # 等待服务启动

# 生成节点 URI
VLESS_URI="vless://$UUID@$DOMAIN:$VLESS_PORT?encryption=none$( [[ $USE_TLS -eq 1 ]] && echo "&security=tls&sni=$DOMAIN&type=tcp&flow=xtls-rprx-vision" || echo "&type=tcp")#VLESS-$DOMAIN"
HY2_URI="hysteria2://hy2user:$HY2_PASS@$DOMAIN:$HY2_PORT?insecure=1#HY2-$DOMAIN"

# 生成二维码
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png

# 端口自检
echo
echo "=================== 端口自检 ==================="
sleep 2
nc -zv 127.0.0.1 $VLESS_PORT &>/dev/null && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
nc -u -z -w3 127.0.0.1 $HY2_PORT &>/dev/null && echo "[✔] HY2 UDP $HY2_PORT 已监听" || echo "[✖] HY2 UDP $HY2_PORT 未监听"

# 输出节点信息
echo
echo "=================== 节点信息 ==================="
echo "VLESS 节点:"
echo "$VLESS_URI"
echo "HY2 节点:"
echo "$HY2_URI"
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"

# 创建 rev 快捷方式
REV_SCRIPT="/root/show_singbox_nodes.sh"
cat > $REV_SCRIPT <<EOF
#!/bin/bash
echo "VLESS 节点:"
echo "$VLESS_URI"
echo "HY2 节点:"
echo "$HY2_URI"
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"
EOF
chmod +x $REV_SCRIPT
echo
echo "快捷显示节点: 输入 rev"
echo "创建 rev 快捷方式完成"

# 卸载脚本
UNINSTALL_SCRIPT="/root/uninstall_singbox.sh"
cat > $UNINSTALL_SCRIPT <<EOF
#!/bin/bash
systemctl stop sing-box
systemctl disable sing-box
rm -rf /etc/sing-box /root/vless_qr.png /root/hy2_qr.png $REV_SCRIPT $UNINSTALL_SCRIPT
apt remove -y sing-box
echo "Sing-box 已卸载"
EOF
chmod +x $UNINSTALL_SCRIPT
echo "卸载: 输入 ./uninstall_singbox.sh"

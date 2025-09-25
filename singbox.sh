#!/bin/bash
# Sing-box 高级一键部署脚本 (VLESS + HY2 + 自动端口 + QR/无域名支持 + rev快捷 + 卸载)
# Author: ChatGPT
set -e

echo "=================== Sing-box 高级部署 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖 (兼容各种 Debian/Ubuntu 版本)
apt update -y
apt install -y curl socat cron openssl qrencode netcat-openbsd || apt install -y curl socat cron openssl qrencode netcat-traditional

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

# 随机端口函数
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# 用户选择节点模式
echo "请选择节点模式:"
echo "1) 有域名 (自动申请 TLS)"
echo "2) 无域名 (使用 VPS IP, 不启用 TLS)"
read -rp "请输入 1 或 2: " MODE

if [[ "$MODE" == "1" ]]; then
    read -rp "请输入你的域名 (例如: lg.lyn.edu.deal): " DOMAIN
    # 检查域名是否指向本机IP
    VPS_IP=$(curl -4s https://api.ip.sb/ip)
    DOMAIN_IP=$(dig +short $DOMAIN @8.8.8.8)
    if [[ "$DOMAIN_IP" != "$VPS_IP" ]]; then
        echo "域名 $DOMAIN 没有解析到当前 VPS IP $VPS_IP，申请证书会失败"
        exit 1
    fi
else
    DOMAIN=""
    VPS_IP=$(hostname -I | awk '{print $1}')
fi

# VLESS TCP 端口
read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
[[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]] && VLESS_PORT=$(get_random_port)

# HY2 UDP 端口
read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]] && HY2_PORT=$(get_random_port)

# UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# TLS 证书目录
CERT_DIR="/etc/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

# 申请证书 (有域名才申请)
if [[ "$MODE" == "1" ]]; then
    echo ">>> 申请 Let's Encrypt TLS 证书"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
      --key-file       "$CERT_DIR/privkey.pem" \
      --fullchain-file "$CERT_DIR/fullchain.pem" --force
fi

# 生成 sing-box 配置
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID" }],$(if [[ "$MODE" == "1" ]]; then echo '"flow":"xtls-rprx-vision",'; fi)
      $(if [[ "$MODE" == "1" ]]; then echo "\"tls\":{\"enabled\":true,\"server_name\":\"$DOMAIN\",\"certificate_path\":\"$CERT_DIR/fullchain.pem\",\"key_path\":\"$CERT_DIR/privkey.pem\"}"; else echo "\"tls\":{\"enabled\":false}"; fi)
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      $(if [[ "$MODE" == "1" ]]; then echo "\"tls\":{\"enabled\":true,\"server_name\":\"$DOMAIN\",\"certificate_path\":\"$CERT_DIR/fullchain.pem\",\"key_path\":\"$CERT_DIR/privkey.pem\"}"; else echo "\"tls\":{\"enabled\":false}"; fi)
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

# 启动 sing-box
systemctl enable sing-box
systemctl restart sing-box
sleep 3

# 节点 IP
NODE_HOST=${DOMAIN:-$VPS_IP}

# 节点 URI
if [[ "$MODE" == "1" ]]; then
    VLESS_URI="vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp&flow=xtls-rprx-vision#VLESS-$NODE_HOST"
else
    VLESS_URI="vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&type=tcp#VLESS-$NODE_HOST"
fi
HY2_URI="hysteria2://hy2user:$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=1#HY2-$NODE_HOST"

# 生成二维码
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png

# 端口自检 (延迟2秒保证服务启动)
sleep 2
check_tcp() { nc -zv -w2 127.0.0.1 $1 &>/dev/null && echo "[✔] VLESS TCP $1 已监听" || echo "[✖] VLESS TCP $1 未监听"; }
check_udp() { timeout 1 bash -c "echo >/dev/udp/127.0.0.1/$1" &>/dev/null && echo "[✔] HY2 UDP $1 已监听" || echo "[✖] HY2 UDP $1 未监听"; }

# 输出信息
echo
echo "=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo -e "二维码文件:\n/root/vless_qr.png\n/root/hy2_qr.png"

echo
echo "=================== 端口自检 ==================="
check_tcp $VLESS_PORT
check_udp $HY2_PORT

# rev 快捷方式
cat > /root/show_singbox_nodes.sh <<EOF
#!/bin/bash
echo -e "VLESS 节点:\\n$VLESS_URI"
echo -e "HY2 节点:\\n$HY2_URI"
echo -e "二维码文件:\\n/root/vless_qr.png\\n/root/hy2_qr.png"
EOF
chmod +x /root/show_singbox_nodes.sh
echo "快捷显示节点: 输入 rev"
echo "创建 rev 快捷方式..."
ln -sf /root/show_singbox_nodes.sh /usr/local/bin/rev

# 卸载脚本
cat > /root/uninstall_singbox.sh <<EOF
#!/bin/bash
systemctl stop sing-box
systemctl disable sing-box
rm -f /etc/systemd/system/sing-box.service
rm -rf /etc/sing-box /root/show_singbox_nodes.sh /usr/local/bin/rev /root/uninstall_singbox.sh /root/vless_qr.png /root/hy2_qr.png
echo "Sing-box 已卸载"
EOF
chmod +x /root/uninstall_singbox.sh
echo "卸载: 输入 ./uninstall_singbox.sh"

echo
echo "=================== 部署完成 ==================="

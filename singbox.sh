#!/bin/bash
# Sing-box 最终一键部署脚本 (VLESS + HY2 + 随机端口 + 无域名模式)
# Author: ChatGPT
# 特性:
# 1. 支持无域名模式（TLS关闭）
# 2. VLESS TCP + HY2 UDP 随机端口
# 3. 自动生成二维码
# 4. rev 快捷显示节点信息
# 5. 启动失败提示

set -e

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖
apt update -y
apt install -y curl socat cron openssl qrencode netcat-openbsd jq dnsutils

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

# 随机端口函数
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q ":$PORT" || break
    done
    echo $PORT
}

# 设置随机端口
read -rp "请输入 VLESS TCP 端口 (默认 443, 输入0随机): " VLESS_PORT
[[ -z "$VLESS_PORT" || "$VLESS_PORT" == "0" ]] && VLESS_PORT=$(get_random_port)

read -rp "请输入 HY2 UDP 端口 (默认 8443, 输入0随机): " HY2_PORT
[[ -z "$HY2_PORT" || "$HY2_PORT" == "0" ]] && HY2_PORT=$(get_random_port)

# 生成 UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)
IP=$(curl -s ipv4.icanhazip.com)

# 创建 sing-box 配置
mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID" }],
      "transport": { "type": "tcp" },
      "tls": { "enabled": false }
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

# 创建节点信息
VLESS_URI="vless://$UUID@$IP:$VLESS_PORT?encryption=none&type=tcp#VLESS-noTLS"
HY2_URI="hysteria2://$HY2_PASS@$IP:$HY2_PORT?insecure=1#HY2-noTLS"
cat > /root/singbox_nodes.env <<EOF
VLESS_URI="$VLESS_URI"
HY2_URI="$HY2_URI"
EOF

# 创建 rev 快捷显示脚本
cat > /root/show_singbox_nodes.sh <<'EOF'
#!/bin/bash
source /root/singbox_nodes.env
echo -e "\n=================== 节点信息 ==================="
echo -e "VLESS 节点:\n$VLESS_URI"
echo -e "HY2 节点:\n$HY2_URI"
echo -e "\nVLESS QR:"
echo "$VLESS_URI" | qrencode -t ansiutf8
echo -e "\nHY2 QR:"
echo "$HY2_URI" | qrencode -t ansiutf8
echo "$VLESS_URI" | qrencode -o /root/vless_qr.png
echo "$HY2_URI" | qrencode -o /root/hy2_qr.png
echo -e "\n二维码文件已生成：/root/vless_qr.png 和 /root/hy2_qr.png"
EOF
chmod +x /root/show_singbox_nodes.sh

# 添加 rev 快捷别名
if ! grep -q "alias rev=" ~/.bashrc; then
    echo "alias rev='/root/show_singbox_nodes.sh'" >> ~/.bashrc
fi

# 创建 systemd 服务
cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run
Restart=on-failure
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动服务
systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

sleep 3

# 检查端口监听
VLESS_STATUS="[✖]"
HY2_STATUS="[✖]"
ss -tuln | grep -q ":$VLESS_PORT" && VLESS_STATUS="[✔]"
ss -tuln | grep -q ":$HY2_PORT" && HY2_STATUS="[✔]"

echo -e "\n=================== 端口自检 ==================="
echo "$VLESS_STATUS VLESS TCP $VLESS_PORT"
echo "$HY2_STATUS HY2 UDP $HY2_PORT"

# 提示服务启动失败
if [[ "$VLESS_STATUS" == "[✖]" || "$HY2_STATUS" == "[✖]" ]]; then
    echo -e "\n[⚠] Sing-box 启动失败，请检查端口是否被占用或配置是否正确"
fi

# 显示节点信息
/root/show_singbox_nodes.sh

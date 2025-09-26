#!/bin/bash
# Sing-box VLESS TCP + HY2 UDP 最小一键安装脚本
# Author: ChatGPT 修正版

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请用 root 运行此脚本${NC}"
    exit 1
fi

# 检查并安装依赖
install_deps() {
    apt-get update -y >/dev/null 2>&1 || yum makecache >/dev/null 2>&1
    apt-get install -y curl wget qrencode >/dev/null 2>&1 || yum install -y curl wget qrencode >/dev/null 2>&1
}

# 安装 sing-box
install_singbox() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${GREEN}正在安装 sing-box...${NC}"
        bash <(curl -fsSL https://sing-box.app/deb-install.sh)
    fi
}

# 生成随机 UUID & HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2PASS=$(openssl rand -base64 12)

# 随机端口
VLESS_PORT=$(shuf -i 20000-40000 -n 1)
HY2_PORT=$(shuf -i 20000-40000 -n 1)

# 服务器 IP
SERVER_IP=$(curl -s4 ip.sb || curl -s4 ifconfig.me)

# 配置目录
mkdir -p /etc/sing-box

# 写入配置文件
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [
        {
          "uuid": "$UUID"
        }
      ],
      "transport": {
        "type": "tcp"
      }
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "password": "$HY2PASS"
        }
      ],
      "tls": {
        "enabled": false
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

# 生成节点链接
VLESS_URL="vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&type=tcp#VLESS-$SERVER_IP"
HY2_URL="hysteria2://hy2user:$HY2PASS@$SERVER_IP:$HY2_PORT?insecure=1#HY2-$SERVER_IP"

# 生成二维码
qrencode -o /root/vless_qr.png "$VLESS_URL"
qrencode -o /root/hy2_qr.png "$HY2_URL"

# 设置 systemd
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run
Restart=always
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

# rev 快捷命令
cat > /usr/bin/rev <<EOF
#!/bin/bash
echo "=================== 节点信息 ==================="
echo "VLESS 节点:"
echo "$VLESS_URL"
echo
echo "HY2 节点:"
echo "$HY2_URL"
echo
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"
EOF
chmod +x /usr/bin/rev

# 卸载脚本
cat > /root/uninstall_singbox.sh <<EOF
#!/bin/bash
systemctl stop sing-box
systemctl disable sing-box
rm -f /etc/systemd/system/sing-box.service
rm -rf /etc/sing-box
rm -f /usr/bin/rev
apt-get remove -y sing-box >/dev/null 2>&1 || yum remove -y sing-box >/dev/null 2>&1
systemctl daemon-reload
echo "Sing-box 已卸载"
EOF
chmod +x /root/uninstall_singbox.sh

# 端口检查
echo "=================== 端口自检 ==================="
sleep 2
if ss -tlnp | grep -q ":$VLESS_PORT "; then
    echo -e "[${GREEN}✔${NC}] VLESS TCP $VLESS_PORT 已监听"
else
    echo -e "[${RED}✖${NC}] VLESS TCP $VLESS_PORT 未监听"
fi
if ss -ulnp | grep -q ":$HY2_PORT "; then
    echo -e "[${GREEN}✔${NC}] HY2 UDP $HY2_PORT 已监听"
else
    echo -e "[${RED}✖${NC}] HY2 UDP $HY2_PORT 未监听"
fi

# 显示信息
echo
echo "=================== 节点信息 ==================="
echo "VLESS 节点:"
echo "$VLESS_URL"
echo
echo "HY2 节点:"
echo "$HY2_URL"
echo
echo "二维码文件:"
echo "/root/vless_qr.png"
echo "/root/hy2_qr.png"
echo
echo "快捷显示节点: 输入 rev"
echo "卸载: 输入 ./uninstall_singbox.sh"

一、环境检查与准备

Root 权限检查：确保以 root 执行，避免权限问题。

公网 IP 检测：自动获取 VPS 公网 IP，用于自签模式的节点 URI。

依赖检查：自动检查必需命令：

curl, ss, openssl, qrencode, dig, systemctl, bash, socat, ufw

缺少任何依赖会提示并中止执行。

端口检查：自动检测 80/443 是否空闲，避免端口冲突。

二、模式选择

域名模式 (Let's Encrypt)：

输入自己的域名（example.com）

自动检查解析是否指向当前 VPS IP

检测已有证书，存在则不重复申请

自动申请证书（ec-256），并安装到 /etc/ssl/sing-box/

**自签模式 (固定域名 www.epple.com)**：

自动生成自签 TLS 证书

CN 为 www.epple.com

SAN 同时包含 www.epple.com 和 VPS 公网 IP

节点 URI 使用 VPS 公网 IP，客户端无需手动修改 IP

Hysteria2 默认 insecure=1，客户端需允许自签证书

三、端口与防火墙

VLESS TCP / Hysteria2 UDP 端口：

支持手动输入，也可输入 0 使用随机端口

防火墙自动放行：

自动开放 80, 443, VLESS 端口, Hysteria2 端口

自动执行 ufw reload

保证外网客户端可以直接访问

四、Sing-box 配置

最新配置格式：

去掉过时字段 decryption，避免 JSON 错误

VLESS + TLS：

UUID 随机生成

TLS SNI 指向域名模式或自签模式的固定域名

Hysteria2 + TLS：

密码随机生成（只包含安全字符，避免 URI 错误）

默认 insecure=1，自签/域名均可无障碍连接

五、节点生成与输出

URI 自动生成：

VLESS: vless://<UUID>@<IP>:<port>?encryption=none&security=tls&sni=<domain>

Hysteria2: hysteria2://<password>@<IP>:<port>?insecure=1&sni=<domain>

QR 码输出：直接显示终端二维码，方便扫码导入客户端

JSON 订阅文件：

/root/singbox_nodes.json

包含 VLESS 和 Hysteria2 节点

客户端可直接导入，无需手动修改

六、启动与状态检查

自动 systemctl enable 和 restart sing-box

检查端口监听状态，输出 VLESS/Hysteria2 是否启动成功

七、总结

一键部署，无需手动修改任何配置

域名/自签模式灵活选择

防火墙端口自动开放

节点 URI 可直接导入客户端，自签证书自动处理 SNI 和 SAN

兼容最新 Sing-box 配置格式，不会报 JSON 错误

Hysteria2 安全密码生成 + 自动 insecure=1 提示客户端

简单说，这个脚本是完全自动化、一键部署、可直接使用的 Sing-box 节点生成器，无论是用自签证书还是域名证书，都能保证客户端直接连通。
bash <(curl -Ls https://raw.githubusercontent.com/hooghub/singbox/main/singbox.sh)

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

    # 检查证书是否已存在
    LE_CERT_PATH="$HOME/.acme.sh/$DOMAIN_ecc/fullchain.cer"
    LE_KEY_PATH="$HOME/.acme.sh/$DOMAIN_ecc/$DOMAIN.key"
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
fi

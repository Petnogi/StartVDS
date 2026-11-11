#!/bin/bash
set -euo pipefail

# --- Цвета для вывода ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}=== Начало настройки сервера ===${NC}"

# --- 1. Сбор данных (с проверкой на пустой ввод) ---
read -rp "Введите имя нового пользователя (например, deploy): " NEW_USER
if [ -z "$NEW_USER" ]; then echo -e "${RED}Имя пользователя не может быть пустым!${NC}"; exit 1; fi

read -rsp "Введите пароль для пользователя $NEW_USER: " USER_PASSWORD; echo
if [ -z "$USER_PASSWORD" ]; then echo -e "${RED}Пароль не может быть пустым!${NC}"; exit 1; fi

read -rp "Введите ваш домен (например, example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then echo -e "${RED}Домен не может быть пустым!${NC}"; exit 1; fi

read -rp "Введите ваш email для Let's Encrypt: " LE_EMAIL
if [ -z "$LE_EMAIL" ]; then echo -e "${RED}Email не может быть пустым!${NC}"; exit 1; fi

read -rsp "Введите ваш Cloudflare API Token (для DNS-01 Challenge): " CF_API_TOKEN; echo
if [ -z "$CF_API_TOKEN" ]; then echo -e "${RED}Токен Cloudflare не может быть пустым!${NC}"; exit 1; fi

read -rsp "Введите токен Cloudflare Tunnel (из панели Zero Trust): " TUNNEL_TOKEN; echo
if [ -z "$TUNNEL_TOKEN" ]; then echo -e "${RED}Токен туннеля не может быть пустым!${NC}"; exit 1; fi

read -rp "Введите порт для панели 3x-ui (например, 2053): " XUI_PORT
if [ -z "$XUI_PORT" ]; then echo -e "${RED}Порт не может быть пустым!${NC}"; exit 1; fi

# --- 2. Обновление системы и установка пакетов ---
echo -e "${GREEN}[1/10] Обновление системы и установка пакетов...${NC}"
apt-get update -y
apt-get upgrade -y
apt-get install -y sudo curl wget nano htop ufw fail2ban unattended-upgrades nginx certbot python3-certbot-dns-cloudflare

# --- 3. Создание пользователя ---
echo -e "${GREEN}[2/10] Создание пользователя $NEW_USER...${NC}"
if id "$NEW_USER" &>/dev/null; then
    echo "Пользователь $NEW_USER уже существует."
else
    useradd -m -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$USER_PASSWORD" | chpasswd
    usermod -aG sudo "$NEW_USER"
    echo "Пользователь $NEW_USER создан и добавлен в группу sudo."
fi

# --- 4. Настройка SSH (пароли оставлены) ---
echo -e "${GREEN}[3/10] Настройка SSH...${NC}"
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication yes
MaxAuthTries 4
LoginGraceTime 30
AllowUsers $NEW_USER
EOF

if sshd -t; then
    systemctl reload ssh
    echo "Конфигурация SSH обновлена."
else
    echo -e "${RED}Ошибка в конфигурации SSH!${NC}"; exit 1
fi

# --- 5. UFW ---
echo -e "${GREEN}[4/10] Настройка UFW...${NC}"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# --- 6. Fail2Ban ---
echo -e "${GREEN}[5/10] Настройка Fail2Ban...${NC}"
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h
findtime = 10m
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# --- 7. Nginx-заглушка ---
echo -e "${GREEN}[6/10] Настройка Nginx-заглушки...${NC}"
mkdir -p /var/www/stub
cat > /var/www/stub/index.html <<EOF
<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>It works!</h1></body></html>
EOF
cat > /etc/nginx/sites-available/stub <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/stub;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
ln -sf /etc/nginx/sites-available/stub /etc/nginx/sites-enabled/stub
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# --- 8. 3x-ui ---
echo -e "${GREEN}[7/10] Установка 3x-ui...${NC}"
export XUI_NONINTERACTIVE=1
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# --- 9. Certbot (Wildcard) ---
echo -e "${GREEN}[8/10] Получение сертификата Let's Encrypt...${NC}"
mkdir -p /etc/letsencrypt
cat > /etc/letsencrypt/cloudflare.ini <<EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
chmod 600 /etc/letsencrypt/cloudflare.ini
certbot certonly --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d "$DOMAIN" -d "*.$DOMAIN" \
    --non-interactive --agree-tos --email "$LE_EMAIL"

# --- 10. Nginx для 3x-ui (HTTPS) ---
echo -e "${GREEN}[9/10] Настройка Nginx для 3x-ui...${NC}"
cat > /etc/nginx/sites-available/xui <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    location / {
        proxy_pass http://127.0.0.1:$XUI_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF
ln -sf /etc/nginx/sites-available/xui /etc/nginx/sites-enabled/xui
nginx -t && systemctl reload nginx

# --- 11. Cloudflare Tunnel ---
echo -e "${GREEN}[10/10] Настройка Cloudflare Tunnel...${NC}"
curl -L --output /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i /tmp/cloudflared.deb
cloudflared service install "$TUNNEL_TOKEN"
systemctl enable cloudflared
systemctl start cloudflared

echo -e "${YELLOW}=== Установка завершена! ===${NC}"
echo -e "${GREEN}Пользователь: $NEW_USER (вход по паролю разрешен)${NC}"
echo -e "${GREEN}Панель 3x-ui: https://$DOMAIN${NC}"
echo -e "${YELLOW}Не забудьте настроить Public Hostname в Cloudflare Zero Trust на https://localhost:443.${NC}"
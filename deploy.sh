#!/bin/bash

# ==============================================================
# Django Deployment Script (Full HTTPS: Let’s Encrypt + Self-signed)
# ==============================================================
# Features:
# - Detects active LAN/mobile IP
# - Updates ALLOWED_HOSTS in settings.py for local + public
# - Sets up Django + Gunicorn + Nginx
# - Let’s Encrypt for public domain
# - Auto self-signed SSL for LAN access
# ==============================================================

# --- Configuration variables ---
PROJECT_NAME="django_alison_lms"
PROJECT_DIR="/home/$USER/$PROJECT_NAME"
VENV_DIR="$PROJECT_DIR/venv"
DJANGO_SETTINGS="$PROJECT_DIR/$PROJECT_NAME/settings.py"
DJANGO_MANAGE="$PROJECT_DIR/manage.py"
PYTHON_BIN="/usr/bin/python3"

# Optional PostgreSQL config
USE_POSTGRES=false
POSTGRES_DB="mydb"
POSTGRES_USER="myuser"
POSTGRES_PASSWORD="mypassword"

# Public domain (for Let’s Encrypt)
DOMAIN_NAME="example.com"   # replace with your actual domain
ADMIN_EMAIL="admin@$DOMAIN_NAME"

# --- Start ---
echo "🚀 Starting full HTTPS hybrid deployment..."

# Detect current active IP
ACTIVE_IF=$(ip route get 1 | awk '{print $5; exit}')
ACTIVE_IP=$(ip -4 addr show $ACTIVE_IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Active network interface: $ACTIVE_IF"
echo "Detected IP: $ACTIVE_IP"

# Configure ALLOWED_HOSTS
ALLOWED_HOSTS=("127.0.0.1" "localhost" "$ACTIVE_IP" "$DOMAIN_NAME")
echo "Updating ALLOWED_HOSTS in settings.py..."
if [ -f "$DJANGO_SETTINGS" ]; then
    sed -i "/^ALLOWED_HOSTS/ d" $DJANGO_SETTINGS
    echo "ALLOWED_HOSTS = ['127.0.0.1', 'localhost', '$ACTIVE_IP', '$DOMAIN_NAME']" >> $DJANGO_SETTINGS
else
    echo "⚠️ settings.py not found. Please check path."
fi

# Update system
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3-pip python3-venv python3-dev \
    nginx git curl build-essential libpq-dev certbot python3-certbot-nginx ufw openssl

# Create virtualenv
mkdir -p $PROJECT_DIR
$PYTHON_BIN -m venv $VENV_DIR
source $VENV_DIR/bin/activate
pip install --upgrade pip

# Install Python dependencies
if [ -f "$PROJECT_DIR/requirements.txt" ]; then
    pip install -r $PROJECT_DIR/requirements.txt
else
    pip install django gunicorn psycopg2-binary
fi

# Database setup (optional)
if [ "$USE_POSTGRES" = true ]; then
    sudo service postgresql start
    sudo -u postgres psql -c "CREATE DATABASE $POSTGRES_DB;"
    sudo -u postgres psql -c "CREATE USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $POSTGRES_USER;"
fi

# Django setup
cd $PROJECT_DIR
source $VENV_DIR/bin/activate
export DJANGO_SETTINGS_MODULE="$PROJECT_NAME.settings"
python $DJANGO_MANAGE migrate
python $DJANGO_MANAGE collectstatic --noinput

# Prompt for superuser
python $DJANGO_MANAGE createsuperuser

# Gunicorn service
sudo tee /etc/systemd/system/$PROJECT_NAME.service > /dev/null <<EOF
[Unit]
Description=Gunicorn daemon for $PROJECT_NAME
After=network.target

[Service]
User=$USER
Group=www-data
WorkingDirectory=$PROJECT_DIR
ExecStart=$VENV_DIR/bin/gunicorn --access-logfile - --workers 3 --bind unix:$PROJECT_DIR/$PROJECT_NAME.sock $PROJECT_NAME.wsgi:application

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl start $PROJECT_NAME
sudo systemctl enable $PROJECT_NAME

# -------------------------
#  Self-signed SSL (LAN)
# -------------------------
SSL_DIR="/etc/ssl/$PROJECT_NAME"
sudo mkdir -p $SSL_DIR

echo "🔒 Generating self-signed certificate for LAN ($ACTIVE_IP)..."
sudo openssl req -x509 -nodes -days 825 \
    -newkey rsa:2048 \
    -keyout $SSL_DIR/selfsigned.key \
    -out $SSL_DIR/selfsigned.crt \
    -subj "/C=PG/ST=NCD/L=Port Moresby/O=LAN/OU=LocalNetwork/CN=$ACTIVE_IP"

# -------------------------
#  Nginx Configuration
# -------------------------
echo "🛠 Configuring Nginx for hybrid HTTPS setup..."

sudo tee /etc/nginx/sites-available/$PROJECT_NAME > /dev/null <<EOF
# Public HTTPS (Let’s Encrypt)
server {
    listen 80;
    server_name $DOMAIN_NAME;
    return 301 https://\$host\$request_uri;
}

# LAN HTTPS (Self-signed)
server {
    listen 443 ssl;
    server_name $ACTIVE_IP;

    ssl_certificate $SSL_DIR/selfsigned.crt;
    ssl_certificate_key $SSL_DIR/selfsigned.key;

    location = /favicon.ico { access_log off; log_not_found off; }
    location /static/ {
        root $PROJECT_DIR;
    }

    location / {
        include proxy_params;
        proxy_pass http://unix:$PROJECT_DIR/$PROJECT_NAME.sock;
    }
}

# Public HTTPS (Let’s Encrypt managed)
server {
    listen 443 ssl;
    server_name $DOMAIN_NAME;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;

    location = /favicon.ico { access_log off; log_not_found off; }
    location /static/ {
        root $PROJECT_DIR;
    }

    location / {
        include proxy_params;
        proxy_pass http://unix:$PROJECT_DIR/$PROJECT_NAME.sock;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/$PROJECT_NAME /etc/nginx/sites-enabled
sudo nginx -t
sudo systemctl restart nginx

# -------------------------
#  Let’s Encrypt for domain
# -------------------------
echo "🌍 Obtaining Let’s Encrypt SSL certificate for $DOMAIN_NAME..."
sudo certbot --nginx -d $DOMAIN_NAME --non-interactive --agree-tos -m $ADMIN_EMAIL || echo "⚠️ Let’s Encrypt setup failed; check domain DNS."

# -------------------------
#  Firewall
# -------------------------
sudo ufw allow 'Nginx Full'

# -------------------------
#  Summary
# -------------------------
echo "✅ Deployment complete!"
echo "------------------------------------------"
echo " Local (LAN) HTTPS:  https://$ACTIVE_IP"
echo " Public (Domain) HTTPS: https://$DOMAIN_NAME"
echo " Gunicorn service:    systemctl status $PROJECT_NAME"
echo " Certificates stored: $SSL_DIR (LAN) + /etc/letsencrypt/live/$DOMAIN_NAME (public)"
echo "------------------------------------------"

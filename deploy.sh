#!/bin/bash

# ==========================
# Django Deployment Script (Hybrid LAN + Public Domain HTTPS)
# ==========================
# Features:
# - Detects active LAN/mobile IP
# - Updates ALLOWED_HOSTS in settings.py for local and public access
# - Sets up Django, Gunicorn, Nginx
# - HTTPS via Let’s Encrypt for public domain
# ==========================

# --- Configuration variables ---
PROJECT_NAME="django_alison_lms"
PROJECT_DIR="/home/$USER/$PROJECT_NAME"
VENV_DIR="$PROJECT_DIR/venv"
DJANGO_SETTINGS="$PROJECT_DIR/$PROJECT_NAME/settings.py"
DJANGO_MANAGE="$PROJECT_DIR/manage.py"
PYTHON_BIN="/usr/bin/python3"

# Optional: PostgreSQL settings
USE_POSTGRES=false
POSTGRES_DB="mydb"
POSTGRES_USER="myuser"
POSTGRES_PASSWORD="mypassword"

# Your public domain pointing to this server (required for Let’s Encrypt)
DOMAIN_NAME="example.com"  # <- replace with your actual domain
ADMIN_EMAIL="admin@$DOMAIN_NAME"

# ---------------------------
# Start deployment
# ---------------------------
echo "Starting hybrid deployment script..."

# Detect active network interface and its IP
ACTIVE_IF=$(ip route get 1 | awk '{print $5; exit}')
ACTIVE_IP=$(ip -4 addr show $ACTIVE_IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Active network interface: $ACTIVE_IF"
echo "Detected active IP: $ACTIVE_IP"

# Set ALLOWED_HOSTS array (LAN IP + public domain + localhost)
ALLOWED_HOSTS=("127.0.0.1" "localhost" "$ACTIVE_IP" "$DOMAIN_NAME")
echo "ALLOWED_HOSTS will be: ${ALLOWED_HOSTS[@]}"

# Update ALLOWED_HOSTS in settings.py
if [ -f "$DJANGO_SETTINGS" ]; then
    echo "Updating ALLOWED_HOSTS in settings.py..."
    sed -i "/^ALLOWED_HOSTS/ d" $DJANGO_SETTINGS
    echo "ALLOWED_HOSTS = ['127.0.0.1', 'localhost', '$ACTIVE_IP', '$DOMAIN_NAME']" >> $DJANGO_SETTINGS
else
    echo "Warning: settings.py not found. Please check PROJECT_DIR."
fi

# Update packages
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3-pip python3-venv python3-dev \
    nginx git curl build-essential libpq-dev certbot python3-certbot-nginx ufw

# Create project directory
mkdir -p $PROJECT_DIR

# Create virtualenv
$PYTHON_BIN -m venv $VENV_DIR
source $VENV_DIR/bin/activate
pip install --upgrade pip

# Install dependencies
if [ -f "$PROJECT_DIR/requirements.txt" ]; then
    pip install -r $PROJECT_DIR/requirements.txt
else
    pip install django gunicorn psycopg2-binary
fi

# Database setup (optional PostgreSQL)
if [ "$USE_POSTGRES" = true ]; then
    sudo service postgresql start
    sudo -u postgres psql -c "CREATE DATABASE $POSTGRES_DB;"
    sudo -u postgres psql -c "CREATE USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';"
    sudo -u postgres psql -c "ALTER ROLE $POSTGRES_USER SET client_encoding TO 'utf8';"
    sudo -u postgres psql -c "ALTER ROLE $POSTGRES_USER SET default_transaction_isolation TO 'read committed';"
    sudo -u postgres psql -c "ALTER ROLE $POSTGRES_USER SET timezone TO 'UTC';"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $POSTGRES_USER;"
fi

# Django migrations & collectstatic
cd $PROJECT_DIR
source $VENV_DIR/bin/activate
export DJANGO_SETTINGS_MODULE="$PROJECT_NAME.settings"
python $DJANGO_MANAGE migrate
python $DJANGO_MANAGE collectstatic --noinput

# Create superuser (interactive)
python $DJANGO_MANAGE createsuperuser

# Gunicorn systemd service
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

# Nginx configuration for both LAN and public domain
sudo tee /etc/nginx/sites-available/$PROJECT_NAME > /dev/null <<EOF
server {
    listen 80;
    server_name $ACTIVE_IP $DOMAIN_NAME;

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

# Firewall
sudo ufw allow 'Nginx Full'

# Obtain HTTPS certificate via Let’s Encrypt (public domain only)
echo "Obtaining Let’s Encrypt SSL certificate for $DOMAIN_NAME..."
sudo certbot --nginx -d $DOMAIN_NAME --non-interactive --agree-tos -m $ADMIN_EMAIL

# Nginx HTTPS redirect for LAN access optional (LAN remains HTTP, public domain HTTPS)
echo "Hybrid deployment complete!"
echo "LAN access: http://$ACTIVE_IP"
echo "Public access: https://$DOMAIN_NAME"

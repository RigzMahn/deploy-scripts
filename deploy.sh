#!/bin/bash

# ==========================
# Django Deployment Script (HTTPS, Auto IP, Update settings.py)
# ==========================
# Fully hands-off deployment:
# - Detects active IP
# - Updates ALLOWED_HOSTS in settings.py
# - Sets up Django, Gunicorn, Nginx
# - Enables HTTPS with self-signed SSL
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

# ---------------------------
# Functions
# ---------------------------
echo "Starting deployment script..."

# Detect active network interface and its IP
ACTIVE_IF=$(ip route get 1 | awk '{print $5; exit}')
ACTIVE_IP=$(ip -4 addr show $ACTIVE_IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Active network interface: $ACTIVE_IF"
echo "Detected active IP: $ACTIVE_IP"

# Set ALLOWED_HOSTS array
ALLOWED_HOSTS=("127.0.0.1" "localhost" "$ACTIVE_IP")
echo "ALLOWED_HOSTS will be: ${ALLOWED_HOSTS[@]}"

# Update ALLOWED_HOSTS in settings.py
if [ -f "$DJANGO_SETTINGS" ]; then
    echo "Updating ALLOWED_HOSTS in settings.py..."
    sed -i "/^ALLOWED_HOSTS/ d" $DJANGO_SETTINGS
    echo "ALLOWED_HOSTS = ['$ACTIVE_IP', '127.0.0.1', 'localhost']" >> $DJANGO_SETTINGS
else
    echo "Warning: settings.py not found. Please check PROJECT_DIR."
fi

# Update packages
echo "Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Install dependencies
echo "Installing required packages..."
sudo apt install -y python3-pip python3-venv python3-dev \
    nginx git curl build-essential libpq-dev openssl ufw

# Create project directory if not exists
mkdir -p $PROJECT_DIR

# Create virtual environment
echo "Creating virtual environment..."
$PYTHON_BIN -m venv $VENV_DIR
source $VENV_DIR/bin/activate

# Upgrade pip
pip install --upgrade pip

# Install project requirements
if [ -f "$PROJECT_DIR/requirements.txt" ]; then
    echo "Installing Python dependencies..."
    pip install -r $PROJECT_DIR/requirements.txt
else
    echo "requirements.txt not found, installing Django and Gunicorn..."
    pip install django gunicorn psycopg2-binary
fi

# Database setup
if [ "$USE_POSTGRES" = true ]; then
    echo "Setting up PostgreSQL..."
    sudo service postgresql start
    sudo -u postgres psql -c "CREATE DATABASE $POSTGRES_DB;"
    sudo -u postgres psql -c "CREATE USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';"
    sudo -u postgres psql -c "ALTER ROLE $POSTGRES_USER SET client_encoding TO 'utf8';"
    sudo -u postgres psql -c "ALTER ROLE $POSTGRES_USER SET default_transaction_isolation TO 'read committed';"
    sudo -u postgres psql -c "ALTER ROLE $POSTGRES_USER SET timezone TO 'UTC';"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $POSTGRES_USER;"
fi

# Django setup
echo "Running Django migrations..."
cd $PROJECT_DIR
source $VENV_DIR/bin/activate
export DJANGO_SETTINGS_MODULE="$PROJECT_NAME.settings"
python $DJANGO_MANAGE migrate
python $DJANGO_MANAGE collectstatic --noinput

# Create superuser (interactive)
echo "You can create a Django superuser now:"
python $DJANGO_MANAGE createsuperuser

# Gunicorn systemd service
echo "Creating Gunicorn systemd service..."
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

# Start and enable Gunicorn
sudo systemctl daemon-reload
sudo systemctl start $PROJECT_NAME
sudo systemctl enable $PROJECT_NAME

# SSL (self-signed)
echo "Generating self-signed SSL certificate..."
SSL_DIR="/etc/ssl/$PROJECT_NAME"
sudo mkdir -p $SSL_DIR
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout $SSL_DIR/$PROJECT_NAME.key \
    -out $SSL_DIR/$PROJECT_NAME.crt \
    -subj "/C=US/ST=State/L=City/O=Organization/OU=IT Department/CN=$ACTIVE_IP"

# Nginx configuration (HTTPS)
echo "Configuring Nginx with HTTPS..."
sudo tee /etc/nginx/sites-available/$PROJECT_NAME > /dev/null <<EOF
server {
    listen 80;
    server_name $ACTIVE_IP;

    # Redirect all HTTP to HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $ACTIVE_IP;

    ssl_certificate $SSL_DIR/$PROJECT_NAME.crt;
    ssl_certificate_key $SSL_DIR/$PROJECT_NAME.key;

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

# Enable site and restart Nginx
sudo ln -sf /etc/nginx/sites-available/$PROJECT_NAME /etc/nginx/sites-enabled
sudo nginx -t
sudo systemctl restart nginx

# Firewall configuration
sudo ufw allow 'Nginx Full'

echo "Deployment finished successfully!"
echo "Your Django site is now accessible at: https://$ACTIVE_IP"

#!/bin/bash

# ==========================
# Django Deployment Script
# ==========================
# This script sets up a Django project with Gunicorn and Nginx
# Author: ChatGPT
# ==========================

# --- Configuration variables ---
PROJECT_NAME="django_alison_lms"
PROJECT_DIR="/home/$USER/$PROJECT_NAME"
VENV_DIR="$PROJECT_DIR/venv"
DJANGO_SETTINGS_MODULE="$PROJECT_NAME.settings"
DJANGO_MANAGE="$PROJECT_DIR/manage.py"
PYTHON_BIN="/usr/bin/python3"

# Replace these with your server IPs
ALLOWED_HOSTS=("127.0.0.1" "localhost" "YOUR_SERVER_IP")

# Optional: PostgreSQL settings
USE_POSTGRES=false
POSTGRES_DB="mydb"
POSTGRES_USER="myuser"
POSTGRES_PASSWORD="mypassword"

# ---------------------------
# Functions
# ---------------------------
echo "Starting deployment script..."

# Update packages
echo "Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Install dependencies
echo "Installing required packages..."
sudo apt install -y python3-pip python3-venv python3-dev \
    nginx git curl build-essential libpq-dev

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
export DJANGO_SETTINGS_MODULE=$DJANGO_SETTINGS_MODULE
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

# Nginx configuration
echo "Configuring Nginx..."
sudo tee /etc/nginx/sites-available/$PROJECT_NAME > /dev/null <<EOF
server {
    listen 80;
    server_name ${ALLOWED_HOSTS[@]};

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

# Firewall (optional)
sudo ufw allow 'Nginx Full'

# SSL (self-signed)
echo "Generating self-signed SSL certificate..."
sudo mkdir -p /etc/ssl/$PROJECT_NAME
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/$PROJECT_NAME/$PROJECT_NAME.key \
    -out /etc/ssl/$PROJECT_NAME/$PROJECT_NAME.crt \
    -subj "/C=US/ST=State/L=City/O=Organization/OU=IT Department/CN=localhost"

echo "Deployment finished successfully!"

#!/bin/bash

# =============================================================
# Django Hybrid HTTPS Network Update Script
# =============================================================
# Use this whenever you switch between LAN or mobile networks.
# It will:
#  - Detect the new local IP
#  - Regenerate self-signed SSL for LAN
#  - Update ALLOWED_HOSTS in settings.py
#  - Restart Gunicorn & Nginx
# =============================================================

PROJECT_NAME="django_alison_lms"
PROJECT_DIR="/home/$USER/$PROJECT_NAME"
DJANGO_SETTINGS="$PROJECT_DIR/$PROJECT_NAME/settings.py"
SSL_DIR="/etc/ssl/$PROJECT_NAME"

# Your public domain (from full deployment)
DOMAIN_NAME="example.com"  # replace with your actual domain

echo "🔍 Detecting active IP..."
ACTIVE_IF=$(ip route get 1 | awk '{print $5; exit}')
ACTIVE_IP=$(ip -4 addr show $ACTIVE_IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "✅ Active IP detected: $ACTIVE_IP ($ACTIVE_IF)"

# Update ALLOWED_HOSTS
if [ -f "$DJANGO_SETTINGS" ]; then
    echo "🧩 Updating ALLOWED_HOSTS in settings.py..."
    sed -i "/^ALLOWED_HOSTS/ d" $DJANGO_SETTINGS
    echo "ALLOWED_HOSTS = ['127.0.0.1', 'localhost', '$ACTIVE_IP', '$DOMAIN_NAME']" >> $DJANGO_SETTINGS
else
    echo "⚠️ settings.py not found. Please check PROJECT_DIR path."
    exit 1
fi

# Regenerate self-signed certificate for LAN
echo "🔒 Regenerating self-signed certificate for LAN ($ACTIVE_IP)..."
sudo mkdir -p $SSL_DIR
sudo openssl req -x509 -nodes -days 825 \
    -newkey rsa:2048 \
    -keyout $SSL_DIR/selfsigned.key \
    -out $SSL_DIR/selfsigned.crt \
    -subj "/C=PG/ST=NCD/L=Port Moresby/O=LAN/OU=LocalNetwork/CN=$ACTIVE_IP"

# Update Nginx LAN block to use the new IP
echo "🛠 Updating Nginx configuration..."
sudo sed -i "s/server_name [0-9\.]*;/server_name $ACTIVE_IP;/" /etc/nginx/sites-available/$PROJECT_NAME

# Test Nginx config and restart services
sudo nginx -t && {
    echo "🔁 Restarting services..."
    sudo systemctl restart nginx
    sudo systemctl restart $PROJECT_NAME
    echo "✅ Network update complete!"
    echo "------------------------------------------"
    echo " LAN HTTPS URL:   https://$ACTIVE_IP"
    echo " Public HTTPS URL: https://$DOMAIN_NAME"
    echo "------------------------------------------"
} || {
    echo "❌ Nginx config test failed! Please review manually."
}

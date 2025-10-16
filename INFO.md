So here’s what we’ll do:
✅ Your update_network.sh will send a short email via the system mailer each time it runs successfully.
✅ Works perfectly with your existing systemd watcher setup.
✅ You can choose any email address (e.g. Gmail, domain email, or even your phone’s SMS gateway).

⚙️ Step 1 — Install a lightweight mailer

Run this once:

sudo apt install -y mailutils


You’ll be prompted to configure postfix. Choose:
➡️ Internet Site
➡️ Enter your system hostname (e.g. server.local or your domain).

This gives you the mail command for sending notifications.

⚙️ Step 2 — Update your update_network.sh script

Here’s the upgraded version with email alerts 👇
Just replace your old version with this one:

#!/bin/bash

# =============================================================
# Django Hybrid HTTPS Network Update Script (with Email Alerts)
# =============================================================
# - Detects new local IP
# - Regenerates self-signed SSL for LAN
# - Updates ALLOWED_HOSTS
# - Restarts Gunicorn & Nginx
# - Sends email notification on success
# =============================================================

PROJECT_NAME="django_alison_lms"
PROJECT_DIR="/home/$USER/$PROJECT_NAME"
DJANGO_SETTINGS="$PROJECT_DIR/$PROJECT_NAME/settings.py"
SSL_DIR="/etc/ssl/$PROJECT_NAME"

# Your public domain
DOMAIN_NAME="example.com"  # replace with your domain
# Notification email
NOTIFY_EMAIL="your_email@example.com"  # replace with your email

# Log file
LOG_FILE="/var/log/django_network_update.log"

echo "🔍 Detecting active IP..." | tee -a $LOG_FILE
ACTIVE_IF=$(ip route get 1 | awk '{print $5; exit}')
ACTIVE_IP=$(ip -4 addr show $ACTIVE_IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "✅ Active IP detected: $ACTIVE_IP ($ACTIVE_IF)" | tee -a $LOG_FILE

# Update ALLOWED_HOSTS
if [ -f "$DJANGO_SETTINGS" ]; then
    echo "🧩 Updating ALLOWED_HOSTS in settings.py..." | tee -a $LOG_FILE
    sed -i "/^ALLOWED_HOSTS/ d" $DJANGO_SETTINGS
    echo "ALLOWED_HOSTS = ['127.0.0.1', 'localhost', '$ACTIVE_IP', '$DOMAIN_NAME']" >> $DJANGO_SETTINGS
else
    echo "⚠️ settings.py not found. Aborting." | tee -a $LOG_FILE
    echo "Django update failed: settings.py missing on $(hostname)" | mail -s "Django Network Update FAILED" $NOTIFY_EMAIL
    exit 1
fi

# Regenerate self-signed certificate for LAN
echo "🔒 Regenerating self-signed certificate for LAN ($ACTIVE_IP)..." | tee -a $LOG_FILE
sudo mkdir -p $SSL_DIR
sudo openssl req -x509 -nodes -days 825 \
    -newkey rsa:2048 \
    -keyout $SSL_DIR/selfsigned.key \
    -out $SSL_DIR/selfsigned.crt \
    -subj "/C=PG/ST=NCD/L=Port Moresby/O=LAN/OU=LocalNetwork/CN=$ACTIVE_IP" >> $LOG_FILE 2>&1

# Update Nginx config for LAN IP
echo "🛠 Updating Nginx configuration..." | tee -a $LOG_FILE
sudo sed -i "s/server_name [0-9\.]*;/server_name $ACTIVE_IP;/" /etc/nginx/sites-available/$PROJECT_NAME

# Test and restart
if sudo nginx -t; then
    echo "🔁 Restarting services..." | tee -a $LOG_FILE
    sudo systemctl restart nginx
    sudo systemctl restart $PROJECT_NAME

    echo "✅ Network update complete at $(date)" | tee -a $LOG_FILE
    echo -e "Django network configuration updated successfully on $(hostname)\n\n\
Active IP: $ACTIVE_IP\nDomain: $DOMAIN_NAME\nTimestamp: $(date)\n\n\
Access locally: https://$ACTIVE_IP\nAccess publicly: https://$DOMAIN_NAME" \
    | mail -s "✅ Django Network Updated ($ACTIVE_IP)" $NOTIFY_EMAIL
else
    echo "❌ Nginx config test failed!" | tee -a $LOG_FILE
    echo "Nginx config test failed on $(hostname) during network update." | mail -s "❌ Django Network Update FAILED" $NOTIFY_EMAIL
fi

⚙️ Step 3 — Set your notification email

Replace:

NOTIFY_EMAIL="your_email@example.com"


with your real address.

You can even use SMS gateways like:

NOTIFY_EMAIL="1234567890@vtext.com"  # for Verizon SMS alerts

⚙️ Step 4 — Test it manually

Run:

./update_network.sh


You should receive an email within a few seconds confirming:

✅ Django Network Updated (192.168.0.xxx)

⚙️ Step 5 — Watch it work automatically

Your existing systemd watcher already triggers this script when you switch networks.
Every time it runs, you’ll automatically get an email like:

Subject: ✅ Django Network Updated (10.42.0.15)

Body:
Active IP: 10.42.0.15
Domain: example.com
Timestamp: 2025-10-15 09:43:00
Access locally: https://10.42.0.15
Access publicly: https://example.com
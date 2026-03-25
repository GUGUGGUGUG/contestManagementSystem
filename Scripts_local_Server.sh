#!/usr/bin/env bash
# =============================================================================
#  CMS LOCAL LAN SETUP SCRIPT
#  For use on a machine connected to a local Wi-Fi router.
#  Contestants access CMS from other devices on the same network via LAN IP.
#  Run this script directly on the host machine (no SSH needed).
# =============================================================================

set -euo pipefail


# =============================================================================
# STEP 1 — INSTALL DEPENDENCIES
# =============================================================================

echo ""
echo "======================================================================"
echo " STEP 1: Installing dependencies"
echo "======================================================================"

sudo apt update && sudo apt upgrade -y

sudo apt-get install -y \
    build-essential openjdk-11-jdk-headless fp-compiler nginx \
    postgresql postgresql-client python3.12 cppreference-doc-en-html \
    cgroup-lite libcap-dev zip make libsystemd-dev pkg-config

sudo apt-get install -y \
    python3.12-dev libpq-dev libcups2-dev libyaml-dev \
    libffi-dev python3-pip

sudo apt-get install -y \
    nginx-full php-cli texlive-latex-base \
    a2ps ghc rustc mono-mcs pypy3

# Fix common errors
sudo apt install -y build-essential python3-babel python3-polib
sudo apt install -y build-essential libcap-dev pkg-config libsystemd-dev
sudo apt install -y python3.10-venv python3-venv
sudo apt install -y libpq-dev
sudo apt install -y python3-dev libpq-dev libcups2-dev build-essential


# =============================================================================
# STEP 2 — CREATE A NON-ROOT USER
# =============================================================================

echo ""
echo "======================================================================"
echo " STEP 2: Creating a non-root user"
echo "======================================================================"

echo "Enter a username for the CMS system user:"
read -r CMS_USER

if id "$CMS_USER" &>/dev/null; then
    echo "User '$CMS_USER' already exists, skipping creation."
else
    adduser "$CMS_USER"
    sudo adduser "$CMS_USER" sudo
fi

echo ""
echo ">> User '$CMS_USER' is ready."
echo ">> IMPORTANT: Switch to that user now and re-run from STEP 3 onward:"
echo ">>   su - $CMS_USER"
echo ">> Then continue the script manually from STEP 3."
echo ""
echo "Press ENTER to continue IF you are already running as '$CMS_USER',"
echo "or Ctrl+C to stop here and switch users first."
read -r _


# =============================================================================
# STEP 3 — DETECT LAN IP
# =============================================================================

echo ""
echo "======================================================================"
echo " STEP 3: Detecting LAN IP address"
echo "======================================================================"

# Auto-detect the machine's LAN IP (first non-loopback IPv4)
LAN_IP=$(hostname -I | awk '{print $1}')

echo "Detected LAN IP: $LAN_IP"
echo "Is this the correct IP your router assigned to this machine? (y/n)"
read -r confirm

if [[ "$confirm" != "y" ]]; then
    echo "Enter your machine's LAN IP manually (e.g. 192.168.1.100):"
    read -r LAN_IP
fi

echo ">> Using LAN IP: $LAN_IP"
echo ">> Admin panel will be accessible at:   http://$LAN_IP:8889  (or via nginx below)"
echo ">> Contest site will be accessible at:  http://$LAN_IP:8888  (or via nginx below)"


# =============================================================================
# STEP 4 — DOWNLOAD AND INSTALL CMS
# =============================================================================

echo ""
echo "======================================================================"
echo " STEP 4: Downloading and installing CMS"
echo "======================================================================"

cd "/home/$CMS_USER"
wget -c https://github.com/cms-dev/cms/releases/download/v1.5.1/v1.5.1.tar.gz
tar -xzf v1.5.1.tar.gz
cd cms

sudo python3 prerequisites.py install


# =============================================================================
# STEP 5 — SET UP PYTHON VENV AND INSTALL PACKAGES
# =============================================================================

echo ""
echo "======================================================================"
echo " STEP 5: Setting up Python virtual environment"
echo "======================================================================"

cd "/home/$CMS_USER"
python3 -m venv ~/cms_venv
cd cms
source ~/cms_venv/bin/activate

pip install --upgrade "setuptools<70"
pip install --upgrade wheel pip
pip install -r requirements.txt
pip install --no-build-isolation .


# =============================================================================
# STEP 6 — SET UP POSTGRESQL DATABASE
# =============================================================================

echo ""
echo "======================================================================"
echo " STEP 6: Setting up PostgreSQL database"
echo "======================================================================"

read -rsp "Enter a password for the PostgreSQL 'cmsuser': " DB_PASSWORD
echo ""

# Run all DB commands as the postgres system user
sudo -u postgres bash <<PGEOF
createuser --pwprompt cmsuser <<< "$DB_PASSWORD
$DB_PASSWORD"
createdb --owner=cmsuser cmsdb
psql --dbname=cmsdb --command='ALTER SCHEMA public OWNER TO cmsuser'
psql --dbname=cmsdb --command='GRANT SELECT ON pg_largeobject TO cmsuser'
PGEOF

echo ">> Database created successfully."


# =============================================================================
# STEP 7 — UPDATE cms.conf
# =============================================================================

echo ""
echo "======================================================================"
echo " STEP 7: Updating cms.conf"
echo "======================================================================"

CONF_FILE="/usr/local/etc/cms.conf"

if [[ ! -f "$CONF_FILE" ]]; then
    echo "Error: $CONF_FILE not found. Did Step 4 complete correctly?" >&2
    exit 1
fi

# Patch database password
sudo sed -i.bak \
    "s|postgresql+psycopg2://cmsuser:your_password_here|postgresql+psycopg2://cmsuser:${DB_PASSWORD}|g" \
    "$CONF_FILE"

# Patch CMS to bind on all interfaces so LAN devices can reach it directly
# (ContestWebServer and AdminWebServer listen addresses)
sudo sed -i \
    's|"contest_listen_address": \[""\]|"contest_listen_address": ["0.0.0.0"]|g' \
    "$CONF_FILE"
sudo sed -i \
    's|"admin_listen_address": ""|"admin_listen_address": "0.0.0.0"|g' \
    "$CONF_FILE"

echo ">> cms.conf updated."
echo ""
echo "IMPORTANT: Please also update the 'secret_key' in $CONF_FILE"
echo "           before running a real contest!"


# =============================================================================
# STEP 8 — CREATE CMS ADMIN ACCOUNT
# =============================================================================

echo ""
echo "======================================================================"
echo " STEP 8: Creating CMS admin account"
echo "======================================================================"

source ~/cms_venv/bin/activate

echo "Enter a username for the CMS admin panel:"
read -r ADMIN_NAME
echo "Enter a password for the CMS admin panel:"
read -rsp "" ADMIN_PASS
echo ""

cmsAddAdmin "$ADMIN_NAME" -p "$ADMIN_PASS"


# =============================================================================
# STEP 9 — CREATE SYSTEMD SERVICES
# =============================================================================

echo ""
echo "======================================================================"
echo " STEP 9: Creating systemd services"
echo "======================================================================"

declare -A extras=(
    [cmsEvaluationService]="-c 1"
    [cmsContestWebServer]="-c 1"
)

services=(
    cmsLogService
    cmsResourceService
    cmsScoringService
    cmsWorker
    cmsEvaluationService
    cmsContestWebServer
    cmsChecker
    cmsAdminWebServer
)

for svc in "${services[@]}"; do
    sudo tee "/etc/systemd/system/${svc}.service" > /dev/null <<EOF
[Unit]
Description=${svc} Service
After=network.target postgresql.service

[Service]
User=${CMS_USER}
ExecStart=/home/${CMS_USER}/cms_venv/bin/${svc} ${extras[$svc]:-}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
done

sudo systemctl daemon-reload
sudo systemctl enable "${services[@]/%/.service}"
sudo systemctl start  "${services[@]/%/.service}"

echo ">> All CMS services started."


# =============================================================================
# STEP 10 — CONFIGURE NGINX FOR LAN ACCESS
# =============================================================================
# Nginx proxies LAN traffic to CMS ports. This lets contestants connect with
# a clean URL like http://192.168.1.100 instead of typing a port number.
# SSL is skipped here since this is a local-only LAN setup.
# =============================================================================

echo ""
echo "======================================================================"
echo " STEP 10: Configuring nginx for LAN access"
echo "======================================================================"

NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

# Remove default site to free up port 80
sudo rm -f "${NGINX_ENABLED}/default"

create_lan_site() {
    local label="$1"   # e.g. "admin" or "contest"
    local port="$2"    # CMS internal port
    local lan_port="$3" # nginx listen port on LAN

    local conf="${NGINX_AVAIL}/cms_${label}.conf"

    sudo tee "${conf}" > /dev/null <<EOF
server {
    listen ${lan_port};
    listen [::]:${lan_port};
    server_name ${LAN_IP};

    # No SSL — local LAN only
    location / {
        proxy_pass         http://127.0.0.1:${port};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF

    [[ -e "${NGINX_ENABLED}/cms_${label}.conf" ]] || \
        sudo ln -s "${conf}" "${NGINX_ENABLED}/"
}

# Admin panel on port 80 (easy to access), Contest on port 8080
create_lan_site "admin"   8889  80
create_lan_site "contest" 8888  8080

sudo nginx -t
sudo systemctl reload nginx


# =============================================================================
# DONE
# =============================================================================

echo ""
echo "======================================================================"
echo " ALL DONE!"
echo "======================================================================"
echo ""
echo "  CMS Admin Panel  → http://${LAN_IP}        (port 80)"
echo "  CMS Contest Site → http://${LAN_IP}:8080   (port 8080)"
echo ""
echo "  Other devices on the same Wi-Fi can open these URLs in a browser."
echo ""
echo "  REMINDERS:"
echo "  1. Update 'secret_key' in /usr/local/etc/cms.conf"
echo "  2. Make sure your firewall/router is NOT blocking ports 80 and 8080"
echo "  3. Keep this machine connected to the Wi-Fi router during the contest"
echo ""

#!/usr/local/bin/bash

# ==============================================================================
# JACOSShield Build Pipeline: Phase 1 (Initialisation) V2.4.0
# Target: FreeBSD 14.0-RELEASE (VirtualBox/VMware VM)
# ==============================================================================

set -e
echo ">>> Starting Phase 1 V2.4.0: Build Node Initialisation"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root."
    exit 1
fi

LOG_DIR="/root/logs/v2.4.0"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/phase1_init.log") 2>&1
echo ">>> Logging to $LOG_DIR/phase1_init.log"


# 1. Install Mandatory Build Tools
echo ">>> Installing pkg dependencies..."
env ASSUME_ALWAYS_YES=YES pkg update
env ASSUME_ALWAYS_YES=YES pkg install poudriere git pkgconf rsync cdrtools bash tmux nginx nano dos2unix

if ! command -v mkisofs >/dev/null 2>&1; then
    echo "ERROR: mkisofs capability missing after cdrtools installation."
    exit 1
fi


# 2. 16GB Swap Creation (Idempotent)
SWAP_FILE="/root/swap.bin"
echo ">>> Ensuring 16GB swap is present and active..."
if [ ! -f "$SWAP_FILE" ]; then
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count=16384
    chmod 0600 "$SWAP_FILE"
fi

if ! swapinfo | grep -q 'md0'; then
    mdconfig -a -t vnode -f "$SWAP_FILE" -u 0
    swapon /dev/md0
fi

if [ ! -f /etc/rc.local ]; then
    echo '#!/bin/sh' > /etc/rc.local
    chmod +x /etc/rc.local
fi

if ! grep -q "$SWAP_FILE" /etc/rc.local; then
    echo "mdconfig -a -t vnode -f $SWAP_FILE -u 0 && swapon /dev/md0" >> /etc/rc.local
fi


# 3. Clone JACOSShield Repositories
echo ">>> Cloning repositories..."
cd /root
[ ! -d 'freebsd-src' ]  && git clone --branch RELENG_2_7_2 --depth 1 https://github.com/iposupinternb3/FreebsdsrcJACOSShield.git freebsd-src
[ ! -d 'freebsd-ports' ] && git clone --branch RELENG_2_7_2 --depth 1 https://github.com/iposup-intern-a1/FreeBSD-ports-JACOSShield.git freebsd-ports
[ ! -d 'pfsense' ]       && git clone --branch RELENG_2_7_2 https://github.com/iposupinternb3/pfsenseJACOSShield.git pfsense


# 4. Generate RSA Signing Keys
echo ">>> Generating Package Signing Keys..."
mkdir -p /root/sign
cd /root/sign
if [ ! -f "repo.key" ]; then
    openssl genrsa -out repo.key 2048
    chmod 0400 repo.key
    openssl rsa -in repo.key -out repo.pub -pubout

    HASH=$(openssl rsa -in repo.key -pubout 2>/dev/null | openssl dgst -sha256 | awk '{print $2}')
    printf 'function: sha256\nfingerprint: "%s"\n' "$HASH" > fingerprint

    cat << 'ENDSIGN' > sign.sh
#!/bin/sh
echo -n "$1 ="
openssl dgst -sha256 -sign /root/sign/repo.key /dev/stdin
ENDSIGN
    chmod +x sign.sh
fi


# 5. Configure Poudriere (V2.4.0)
#   PARALLEL_JOBS=1
#   USE_TMPFS=no
#   MAX_MEMORY=14
#   NO_PLIST_CHECK=yes
#   CHECK_PLIST=no
ZPOOL_NAME="$(zpool list -H -o name 2>/dev/null | head -n 1)"
ZPOOL_NAME="${ZPOOL_NAME:-zroot}"
echo ">>> Configuring Poudriere on pool: $ZPOOL_NAME"

mkdir -p /usr/local/etc
cat << EOF > /usr/local/etc/poudriere.conf
ZPOOL=$ZPOOL_NAME
BASEFS=/usr/local/poudriere
POUDRIERE_DATA=/usr/local/poudriere/data
ALLOW_MAKE_JOBS=yes
PARALLEL_JOBS=1
USE_TMPFS=no
DISTFILES_CACHE=/usr/ports/distfiles
TMPFS_LIMIT=4
MAX_MEMORY=14
NOLINUX=yes
NO_PLIST_CHECK=yes
CHECK_PLIST=no
EOF
mkdir -p /usr/ports/distfiles


# 6. Configure Nginx
echo ">>> Configuring Nginx..."
cat << 'EOF' > /usr/local/etc/nginx/nginx.conf
events { worker_connections 1024; }
http {
    include mime.types;
    default_type application/octet-stream;
    server {
        listen 80;
        server_name localhost;
        root /usr/local/www/nginx;
        autoindex on;
        location / { try_files $uri $uri/ =404; }
    }
}
EOF

mkdir -p /usr/local/poudriere/data/packages
mkdir -p /usr/local/www/nginx
ln -sfn /usr/local/poudriere/data/packages /usr/local/www/nginx/packages

sysrc nginx_enable=YES
service nginx restart || service nginx start

echo ">>> Phase 1 V2.4.0 Complete. Proceed to Phase 2."

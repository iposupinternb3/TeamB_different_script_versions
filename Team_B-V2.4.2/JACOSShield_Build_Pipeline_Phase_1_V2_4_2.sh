#!/usr/local/bin/bash

# ==============================================================================
# JACOSShield Build Pipeline: Phase 1 (Initialisation) V2.4.2
# Target: FreeBSD 14.0-RELEASE (VirtualBox/VMware VM)
#
# Changes from V2.4.1:
#   FIX L1   — SRCCONF added to build.conf pointing to freebsd-src copy;
#               builder_defaults.sh patched to use :- operator so build.conf
#               takes priority. Eliminates "SRCCONF pointing to nonexistent
#               file …tmp/FreeBSD-src/release/conf/pfSense_src.conf".
#   FIX L2   — pfSense_src.conf corrected: WITH_META_MODE=YES removed.
#               META_MODE cannot be in SRCCONF — only in SRC_ENV_CONF.
#   FIX L3   — WITHOUT_LIB32=YES added to pfSense_src-env.conf and
#               pfSense_src.conf so buildworld skips 32-bit shim libraries.
#   FIX L17  — sign.sh rewritten to use 'read -t 60 sum' instead of piping
#               to openssl /dev/stdin. Old form hung forever because pkg repo
#               never sent data to the pipe.
#   FIX L23  — JACOSShield_src.conf symlink created (7th JACOS symlink).
#               Only 6 existed; the missing one caused a SRCCONF lookup fail.
#   FIX RAM1 — ZFS ARC cache limited to 512MB via sysctl vfs.zfs.arc_max
#               and persisted in /etc/sysctl.conf. Prevents llvm15/rust OOM.
#   FIX RAM2 — Extra 8GB vnode swap (/root/swap2.bin on md1) added on top
#               of the 16GB swap.bin. Total swap: 24GB. Persisted in rc.local.
#   FIX RAM3 — MAKE_JOBS_NUMBER_LIMIT=1 added to poudriere.conf so llvm15
#               and rust compile single-threaded and do not exhaust RAM.
# ==============================================================================

set -e
echo ">>> Starting Phase 1 V2.4.2: Build Node Initialisation"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root."
    exit 1
fi

LOG_DIR="/root/logs/v2.4.2"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/phase1_init.log") 2>&1
echo ">>> Logging to $LOG_DIR/phase1_init.log"


# ==============================================================================
# 0. SSH Key & Agent Check (Required for git@ SSH clone)
#
# All three repos use git@github.com: (SSH) URLs. The build VM must have:
#   a) An SSH keypair at /root/.ssh/id_rsa (or id_ed25519)
#   b) The public key added to the iposupinternb3 GitHub account
#   c) github.com in known_hosts (added here automatically via ssh-keyscan)
#
# If your key is NOT at /root/.ssh/id_rsa or id_ed25519, export SSH_IDENTITY:
#   export SSH_IDENTITY=/path/to/your/key
#   then re-run this script.
# ==============================================================================
echo ">>> Checking SSH key setup for git@github.com clones..."
SSH_KEY="${SSH_IDENTITY:-}"
[ -z "$SSH_KEY" ] && [ -f /root/.ssh/id_ed25519 ] && SSH_KEY=/root/.ssh/id_ed25519
[ -z "$SSH_KEY" ] && [ -f /root/.ssh/id_rsa      ] && SSH_KEY=/root/.ssh/id_rsa

[ -z "$SSH_KEY" ] && {
    echo "ERROR: No SSH private key found at /root/.ssh/id_ed25519 or /root/.ssh/id_rsa."
    echo "  Generate one with:  ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ''"
    echo "  Then add the public key (/root/.ssh/id_ed25519.pub) to GitHub:"
    echo "    https://github.com/settings/keys  (account: iposupinternb3)"
    echo "  Then re-run this script."
    exit 1
}
echo "  SSH key: $SSH_KEY"

# Add github.com to known_hosts (idempotent — safe to run multiple times)
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if ! grep -q "github.com" /root/.ssh/known_hosts 2>/dev/null; then
    ssh-keyscan -H github.com >> /root/.ssh/known_hosts 2>/dev/null
    echo "  github.com added to known_hosts."
else
    echo "  github.com already in known_hosts."
fi

# Quick connectivity test — fail fast with a clear message
GIT_SSH_COMMAND="ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=15" \
    git ls-remote git@github.com:iposupinternb3/pfsense.git HEAD >/dev/null 2>&1 || {
    echo "ERROR: SSH authentication to github.com failed."
    echo "  Key used: $SSH_KEY"
    echo "  Make sure this key's public part is on: https://github.com/settings/keys"
    echo "  Test manually: ssh -T -i $SSH_KEY git@github.com"
    exit 1
}
echo "  SSH auth to github.com: OK"

# Export for all subsequent git commands in this session
export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no"
echo ">>> SSH setup: OK"


# ==============================================================================
# 1. Install Mandatory Build Tools
# ==============================================================================
echo ">>> Installing pkg dependencies..."
env ASSUME_ALWAYS_YES=YES IGNORE_OSVERSION=yes pkg update
env ASSUME_ALWAYS_YES=YES IGNORE_OSVERSION=yes pkg install \
    poudriere git pkgconf rsync cdrtools bash tmux nginx nano dos2unix \
    python3 gtar xmlstarlet

# Fix: xmlstarlet on FreeBSD is installed as "xml", create symlink if needed
[ ! -f /usr/local/bin/xmlstarlet ] && [ -f /usr/local/bin/xml ] && \
    ln -sf /usr/local/bin/xml /usr/local/bin/xmlstarlet

for CMD in mkisofs python3 gtar xmlstarlet; do
    command -v "$CMD" >/dev/null 2>&1 || { echo "ERROR: $CMD missing."; exit 1; }
done
echo ">>> All build tools verified."


# ==============================================================================
# 2. Swap Setup (FIX RAM2)
#
# Creates two vnode swap files:
#   /root/swap.bin  — 16GB on md0 (same as V2.4.1)
#   /root/swap2.bin —  8GB on md1 (NEW in V2.4.2)
# Total: 24GB vnode swap, persisted via rc.local.
# Required because llvm15 and rust each need 4-6GB RAM/swap to compile.
# ==============================================================================
SWAP_FILE="/root/swap.bin"
SWAP_FILE2="/root/swap2.bin"

echo ">>> Ensuring 16GB primary vnode swap (md0)..."
if [ ! -f "$SWAP_FILE" ]; then
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count=16384
    chmod 0600 "$SWAP_FILE"
fi
if ! swapinfo | grep -q 'md0'; then
    mdconfig -a -t vnode -f "$SWAP_FILE" -u 0
    swapon /dev/md0
fi

echo ">>> Ensuring 8GB secondary vnode swap (md1) — FIX RAM2..."
if [ ! -f "$SWAP_FILE2" ]; then
    dd if=/dev/zero of="$SWAP_FILE2" bs=1M count=8192
    chmod 0600 "$SWAP_FILE2"
fi
if ! swapinfo | grep -q 'md1'; then
    mdconfig -a -t vnode -f "$SWAP_FILE2" -u 1
    swapon /dev/md1
fi

# Persist both swap files across reboots via rc.local
if [ ! -f /etc/rc.local ]; then
    echo '#!/bin/sh' > /etc/rc.local
    chmod +x /etc/rc.local
fi
grep -q "$SWAP_FILE" /etc/rc.local || \
    echo "mdconfig -a -t vnode -f $SWAP_FILE -u 0 && swapon /dev/md0" >> /etc/rc.local
grep -q "$SWAP_FILE2" /etc/rc.local || \
    echo "mdconfig -a -t vnode -f $SWAP_FILE2 -u 1 && swapon /dev/md1" >> /etc/rc.local

echo ">>> Swap summary:"
swapinfo -g


# ==============================================================================
# 2a. ZFS ARC Cache Limit (FIX RAM1)
#
# By default ZFS ARC grows to fill all free RAM. On a 10GB VM this leaves
# only ~200MB free for compilers, causing llvm15 and rust to OOM-crash.
# Limiting ARC to 512MB frees ~7GB for the build.
# Persisted in /etc/sysctl.conf so it survives reboots.
# ==============================================================================
echo ">>> Limiting ZFS ARC to 512MB (FIX RAM1)..."
sysctl vfs.zfs.arc_max=536870912
if ! grep -q "vfs.zfs.arc_max" /etc/sysctl.conf 2>/dev/null; then
    echo "vfs.zfs.arc_max=536870912" >> /etc/sysctl.conf
    echo "  vfs.zfs.arc_max persisted in /etc/sysctl.conf"
else
    # Update existing value
    sed -i '' 's/^vfs.zfs.arc_max=.*/vfs.zfs.arc_max=536870912/' /etc/sysctl.conf
    echo "  vfs.zfs.arc_max updated in /etc/sysctl.conf"
fi
echo "  ARC max: $(sysctl -n vfs.zfs.arc_max) bytes (512MB)"


# ==============================================================================
# 3. Clone Repositories
# ==============================================================================
echo ">>> Cloning repositories..."
cd /root
for REPO in \
    "freebsd-src git@github.com:iposupinternb3/FreeBSD-src.git RELENG_2_7_2" \
    "freebsd-ports git@github.com:iposupinternb3/FreeBSD-ports.git master" \
    "pfsense git@github.com:iposupinternb3/pfsense.git master"; do
    set -- $REPO
    DIR="$1"; URL="$2"; BRANCH="$3"
    if [ ! -d "$DIR" ]; then
        if [ -n "$BRANCH" ]; then
            git clone --branch "$BRANCH" --depth 1 "$URL" "$DIR"
        else
            git clone "$URL" "$DIR"
        fi
    else
        echo "  $DIR already present — skipping."
    fi
    [ -d "/root/$DIR/.git" ] || { echo "ERROR: /root/$DIR not cloned."; exit 1; }
done
echo ">>> All repositories verified."


# ==============================================================================
# 4. Fix FreeBSD Source Config Files (FIX L2, L3, L23)
# ==============================================================================
echo ">>> Fixing FreeBSD source config files (L2, L3, L23)..."
CONF_DIR="/root/freebsd-src/release/conf"
mkdir -p "$CONF_DIR"

# pfSense_src.conf — SRCCONF: no META_MODE, disable lib32 and system compiler
cat > "$CONF_DIR/pfSense_src.conf" << 'EOF'
WITHOUT_SYSTEM_COMPILER=YES
WITHOUT_LIB32=YES
EOF
echo "  pfSense_src.conf: $(cat "$CONF_DIR/pfSense_src.conf")"

# pfSense_src-env.conf — SRC_ENV_CONF: compiler type, lib32
cat > "$CONF_DIR/pfSense_src-env.conf" << 'EOF'
WITHOUT_SYSTEM_COMPILER=YES
WITHOUT_LIB32=YES
EOF
echo "  pfSense_src-env.conf: $(cat "$CONF_DIR/pfSense_src-env.conf")"

# pfSense_make.conf
if [ -f "$CONF_DIR/pfSense_make.conf" ]; then
    grep -q "WITHOUT_LIB32" "$CONF_DIR/pfSense_make.conf" || \
        echo "WITHOUT_LIB32=YES" >> "$CONF_DIR/pfSense_make.conf"
else
    echo "WITHOUT_LIB32=YES" > "$CONF_DIR/pfSense_make.conf"
fi
echo "  pfSense_make.conf: OK"

# FIX L23: Create JACOSShield_src.conf symlink if missing
if [ ! -e "$CONF_DIR/JACOSShield_src.conf" ]; then
    ln -s pfSense_src.conf "$CONF_DIR/JACOSShield_src.conf"
    echo "  Created JACOSShield_src.conf symlink."
else
    echo "  JACOSShield_src.conf symlink already present."
fi

# Ensure the other 6 standard JACOS symlinks exist
for SRC in pfSense_make.conf pfSense_src-env.conf pfSense_build_src.conf \
           pfSense_install_src.conf pfSense_installer_make.conf \
           pfSense_installer_src.conf; do
    JACOS="${SRC/pfSense/JACOSShield}"
    if [ ! -e "$CONF_DIR/$JACOS" ] && [ -f "$CONF_DIR/$SRC" ]; then
        ln -s "$SRC" "$CONF_DIR/$JACOS"
        echo "  Created symlink: $JACOS -> $SRC"
    fi
done

echo ">>> JACOS conf symlink count: $(ls "$CONF_DIR"/JACOSShield_*.conf 2>/dev/null | wc -l)"


# ==============================================================================
# 5. Fix sign.sh (FIX L17)
# ==============================================================================
echo ">>> Fixing sign.sh (L17)..."
mkdir -p /root/sign
if [ -f /root/sign/repo.key ]; then
    echo "  RSA key already present — keeping."
else
    openssl genrsa -out /root/sign/repo.key 2048
    chmod 0400 /root/sign/repo.key
    openssl rsa -in /root/sign/repo.key -out /root/sign/repo.pub -pubout
    HASH=$(openssl rsa -in /root/sign/repo.key -pubout 2>/dev/null | \
           openssl dgst -sha256 | awk '{print $2}')
    printf 'function: sha256\nfingerprint: "%s"\n' "$HASH" > /root/sign/fingerprint
fi

cat > /root/sign/sign.sh << 'SIGNEOF'
#!/bin/sh
# V2.4.2: read hash from stdin via 'read' so pkg repo's pipe drains correctly.
read -t 60 sum
echo "${sum}" | openssl dgst -sha256 -sign /root/sign/repo.key -binary | openssl base64
SIGNEOF
chmod +x /root/sign/sign.sh
echo "  sign.sh rewritten. Test:"
echo "abc123" | /root/sign/sign.sh 2>/dev/null | head -c 40 && echo "... OK"


# ==============================================================================
# 6. Configure Poudriere (FIX RAM3)
#
# FIX RAM3: MAKE_JOBS_NUMBER_LIMIT=1 added so llvm15 and rust compile
# single-threaded. Without this, parallel compilation spawns dozens of
# cc1/rustc processes simultaneously, exhausting all RAM and swap.
# ==============================================================================
ZPOOL_NAME="$(zpool list -H -o name 2>/dev/null | head -n 1)"
ZPOOL_NAME="${ZPOOL_NAME:-zroot}"
echo ">>> Configuring Poudriere on ZFS pool: $ZPOOL_NAME (FIX RAM3)..."
mkdir -p /usr/local/etc
cat << EOF > /usr/local/etc/poudriere.conf
ZPOOL=$ZPOOL_NAME
BASEFS=/usr/local/poudriere
POUDRIERE_DATA=/usr/local/poudriere/data
ALLOW_MAKE_JOBS=yes
PARALLEL_JOBS=1
MAKE_JOBS_NUMBER_LIMIT=1
USE_TMPFS=no
DISTFILES_CACHE=/usr/ports/distfiles
TMPFS_LIMIT=4
MAX_MEMORY=14
NOLINUX=yes
NO_PLIST_CHECK=yes
CHECK_PLIST=no
EOF
mkdir -p /usr/ports/distfiles
echo "  poudriere.conf written with MAKE_JOBS_NUMBER_LIMIT=1"


# ==============================================================================
# 7. Configure Nginx
# ==============================================================================
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
        disable_symlinks off;
        location / { try_files $uri $uri/ =404; }
    }
}
EOF
mkdir -p /usr/local/poudriere/data/packages /usr/local/www/nginx
ln -sfn /usr/local/poudriere/data/packages /usr/local/www/nginx/packages
sysrc nginx_enable=YES
service nginx restart || service nginx start
echo "  Nginx started."


# ==============================================================================
# 8. Summary
# ==============================================================================
echo ""
echo "============================================================"
echo " Phase 1 V2.4.2 Complete."
echo " Log:    $LOG_DIR/phase1_init.log"
echo " Swap:   $(swapinfo -g | awk 'NR>1{sum+=$2} END{print sum"GB total"}')"
echo " ARC:    $(sysctl -n vfs.zfs.arc_max) bytes (512MB limit)"
echo " Nginx:  $(service nginx status | grep -o 'is running' || echo 'NOT running')"
echo " JACOS conf symlinks: $(ls /root/freebsd-src/release/conf/JACOSShield_*.conf 2>/dev/null | wc -l)"
echo " sign.sh: $(ls -la /root/sign/sign.sh)"
echo " Signing: DISABLED (DO_NOT_SIGN_PKG_REPO=1 set in Phase 2)"
echo " RAM fixes: ARC=512MB, Swap=24GB, MAKE_JOBS=1"
echo " Proceed to: Phase 2"
echo "============================================================"

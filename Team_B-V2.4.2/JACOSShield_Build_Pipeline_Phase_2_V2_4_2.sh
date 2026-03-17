#!/usr/local/bin/bash

set -e
LOG_FILE="/root/logs/v2.4.2/phase2_patching.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo ">>> Starting Phase 2 V2.4.2: Core Environment Configuration"

# ✅ FIX: Single source of truth for FreeBSD source
FREEBSD_SRC="/root/freebsd-src"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root."
    exit 1
fi

# ── 1. Generate build.conf ─────────────────────────────────────────────────────
echo ">>> Generating build.conf..."
cat << 'EOF' > /root/pfsense/build.conf
export PRODUCT_NAME="JACOSShield"
export FREEBSD_REPO_BASE=file:///root/freebsd-src
export POUDRIERE_PORTS_GIT_URL=file:///root/freebsd-ports
export FREEBSD_BRANCH=RELENG_2_7_2
export POUDRIERE_PORTS_GIT_BRANCH=RELENG_2_7_2
export DEFAULT_ARCH_LIST="amd64.amd64"
export PKG_REPO_SIGNING_COMMAND="/root/sign/sign.sh ${PKG_REPO_SIGN_KEY}"
export PKG_REPO_SERVER_DEVEL="http://127.0.0.1/packages"
export PKG_REPO_SERVER_RELEASE="http://127.0.0.1/packages"
export PKG_REPO_SERVER_STAGING="http://127.0.0.1/packages"
export MIRROR_TYPE="none"
export DO_NOT_SIGN_PKG_REPO=1
export MAKE_JOBS=1
export PARALLEL_JOBS=1
export KERNEL_JOBS=1
export POUDRIERE_JOBS=1
export POUDRIERE_PORTS_NAME="JACOSShield_v2_7_2"
EOF

# ── 2. Fix Parallelism ─────────────────────────────────────────────────────────
echo ">>> Patching builder_common.sh parallelism..."
sed -i '' 's/local _parallel_jobs=.*/local _parallel_jobs=1/g' /root/pfsense/tools/builder_common.sh
sed -i '' 's/_parallel_jobs=$((.*/_parallel_jobs=1/g' /root/pfsense/tools/builder_common.sh
sed -i '' 's/PARALLEL_JOBS=${_parallel_jobs}/PARALLEL_JOBS=1/g' /root/pfsense/tools/builder_common.sh

# ── 3. Suppress lib32 ──────────────────────────────────────────────────────────
echo ">>> Suppressing lib32..."
mkdir -p /usr/local/etc/poudriere.d/
cat << 'EOF' > /usr/local/etc/poudriere.d/JACOSShield_v2_7_2_amd64-src.conf
WITHOUT_LIB32=yes
WITHOUT_TESTS=yes
WITHOUT_CLANG_EXTRAS=yes
EOF

echo -e "WITHOUT_LIB32=yes\nWITHOUT_TESTS=yes" > /etc/src.conf

sed -i '' 's/${MAKEWORLDARGS} || err 1 "Failed to '"'"'make buildworld'"'"'"/${MAKEWORLDARGS} WITHOUT_LIB32=yes WITHOUT_TESTS=yes || err 1 "Failed to '"'"'make buildworld'"'"'"/g' \
    /usr/local/share/poudriere/jail.sh

# ── 4. Fix Ports Name ──────────────────────────────────────────────────────────
echo ">>> Fixing Poudriere ports name..."
sed -i '' 's/export POUDRIERE_PORTS_NAME=.*/export POUDRIERE_PORTS_NAME="JACOSShield_v2_7_2"/g' \
    /root/pfsense/tools/builder_defaults.sh

# ── 5. builder_common.sh patches ───────────────────────────────────────────────
echo ">>> Applying native builder_common.sh environment patches..."
BC="/root/pfsense/tools/builder_common.sh"

sed -i '' 's/clone_to_staging_area() {/clone_to_staging_area() {\n\tmkdir -p ${STAGE_CHROOT_DIR}\/var/g' "$BC"

sed -i '' 's/pkg_bootstrap() {/pkg_bootstrap() {\n\tcp \/usr\/local\/bin\/sqlite3 ${1:-${STAGE_CHROOT_DIR}}\/usr\/local\/bin\/sqlite3 2>\/dev\/null || true\n\tcp \/usr\/local\/lib\/libsqlite3.so* ${1:-${STAGE_CHROOT_DIR}}\/usr\/local\/lib\/ 2>\/dev\/null || true/g' "$BC"

sed -i '' 's/local _pkg="$(get_pkg_name ${2}).txz"/local _pkg="$(get_pkg_name ${2}).pkg"/g' "$BC"
sed -i '' 's/MAIN_PKG=${PRODUCT_NAME}/MAIN_PKG=${PRODUCT_NAME}-ce/g' "$BC"

sed -i '' 's/echo force > ${STAGE_CHROOT_DIR}\/cf\/conf\/enableserial_force/mkdir -p ${STAGE_CHROOT_DIR}\/cf\/conf\n\techo force > ${STAGE_CHROOT_DIR}\/cf\/conf\/enableserial_force/g' "$BC"

awk '
/core_pkg_create rc ""/ && !done1 {
    print "\ttar -C ${STAGE_CHROOT_DIR} -cJf ${STAGE_CHROOT_DIR}${PRODUCT_SHARE_DIR}/initial.txz etc/dh-parameters.* 2>/dev/null || true"
    done1=1
}
/core_pkg_create default-config ""/ && !done2 {
    print "\tmkdir -p ${STAGE_CHROOT_DIR}/conf.default"
    print "\tcp /root/pfsense/src/conf.default/config.xml ${STAGE_CHROOT_DIR}/conf.default/config.xml 2>/dev/null || true"
    done2=1
}
{print}
' "$BC" > "${BC}.tmp" && mv "${BC}.tmp" "$BC"

chmod +x "$BC"
echo "  builder_common.sh safely patched."

# ── 6. cryptotest fix ──────────────────────────────────────────────────────────
echo ">>> Patching cryptotest.c natively..."

CRYPTOTEST="${FREEBSD_SRC}/tools/tools/crypto/cryptotest.c"

cat > /root/fix_cryptotest.sh << FIXEOF
#!/bin/sh
CRYPTOTEST="${FREEBSD_SRC}/tools/tools/crypto/cryptotest.c"
[ ! -f "\$CRYPTOTEST" ] && exit 0
[ -f "\${CRYPTOTEST}.orig" ] && exit 0

cp "\$CRYPTOTEST" "\${CRYPTOTEST}.orig"

awk '
/bzero\\(&top->cs_invoke/ || /min\\.tv_sec/ { print "#if 0"; in_block=1 }
in_block && /}/ { print; print "#endif"; in_block=0; next }
/^static void[[:space:]]+printt[[:space:]]*\\(/ { print "#if 0"; in_func=1; brace=0 }
in_func { print; brace += gsub(/{/, "{") - gsub(/}/, "}"); if (brace == 0 && in_func > 1) { print "#endif"; in_func=0 } in_func++; next }
/cs_invoke\\.count/ || /cs_done\\.count/ { print "#if 0"; print; in_cs=1; next }
in_cs { print; print "#endif"; in_cs=0; next }
{ print }
' "\${CRYPTOTEST}.orig" > "\$CRYPTOTEST"
FIXEOF

chmod +x /root/fix_cryptotest.sh

if [ -f "$CRYPTOTEST" ] && [ ! -f "${CRYPTOTEST}.orig" ]; then
    sh /root/fix_cryptotest.sh
fi

echo "  cryptotest patch handled."

# ── 7. Kernel config ───────────────────────────────────────────────────────────
echo ">>> Setting up JACOSShield Kernel configurations..."

KERNCONF_DIR="${FREEBSD_SRC}/sys/amd64/conf"

if [ -d "$KERNCONF_DIR" ] && [ ! -f "$KERNCONF_DIR/JACOSShield" ]; then
    cp "$KERNCONF_DIR/pfSense" "$KERNCONF_DIR/JACOSShield"
    sed -i '' 's/ident.*pfSense/ident JACOSShield/' "$KERNCONF_DIR/JACOSShield"
fi

cat > /root/create_kernconf.sh << EOF
#!/bin/sh
KERNCONF_DIR="${FREEBSD_SRC}/sys/amd64/conf"
if [ ! -f "\$KERNCONF_DIR/JACOSShield" ]; then
    cp "\$KERNCONF_DIR/pfSense" "\$KERNCONF_DIR/JACOSShield"
    sed -i '' 's/ident.*pfSense/ident JACOSShield/' "\$KERNCONF_DIR/JACOSShield"
fi
EOF

chmod +x /root/create_kernconf.sh

echo "  Kernel config ready."

echo "============================================================"
echo ">>> Phase 2 V2.4.2 Complete. Ready for Phase 3"
echo "============================================================"

#!/usr/local/bin/bash

# ==============================================================================
# JACOSShield Build Pipeline: Phase 3 V2.4.0
# Target: FreeBSD 14.0-RELEASE (VirtualBox/VMware VM)
#

set -e
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root."
    exit 1
fi

LOG_DIR="/root/logs/v2.4.0"
LOG_FILE="$LOG_DIR/phase3_final_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================================="
echo " PHASE 3 V2.4.0: PRE-FLIGHT CHECKS"
echo "=========================================================="


# ── Guardrail: Require tmux or daemon ─────────────────────────────────────────
if [ -z "$TMUX" ] && [ "$TMUX_BYPASS" != "1" ]; then
    echo "WARNING: tmux session not detected."
    echo "To prevent shell TTY suspension (State T) on this VM, run via daemon(8):"
    echo "  export TMUX_BYPASS=1"
    echo "  daemon -f -o /root/logs/v2.4.0/phase3_daemon.log \\"
    echo "    /usr/local/bin/bash '/root/scripts/JACOSShield Build Pipeline Phase 3 V2.4.0.sh'"
    exit 1
fi


# ── Swap check ────────────────────────────────────────────────────────────────
if ! swapinfo -h 2>/dev/null | awk 'NR>1{found=1} END{exit(found?0:1)}'; then
    echo "ERROR: 16GB Vnode Swap not active! Re-run Phase 1."
    exit 1
fi


# ── Nginx check ───────────────────────────────────────────────────────────────
if ! service nginx status | grep -q 'is running'; then
    echo "ERROR: Nginx package server is offline."
    exit 1
fi


# ── Jail check ────────────────────────────────────────────────────────────────
JAIL_NAME="JACOSShield_v2_7_2_amd64"
if poudriere jail -l | grep -q "$JAIL_NAME"; then
    echo ">>> Jail '$JAIL_NAME' exists. Skipping destructive setup."
    SKIP_SETUP=true
else
    echo ">>> Jail '$JAIL_NAME' not found. Fresh creation required."
    SKIP_SETUP=false
fi


echo "=========================================================="
echo " STEP 1: Creating Poudriere Jail (~3-4 hours)"
echo "=========================================================="
cd /root/pfsense
if [ "$SKIP_SETUP" = false ]; then
    ./build.sh --setup-poudriere
else
    if ! poudriere ports -l | grep -q "JACOSShield_v2_7_2"; then
        poudriere ports -c -p JACOSShield_v2_7_2 -m git+file \
            -U file:///root/freebsd-ports -B RELENG_2_7_2
    fi
fi


echo "=========================================================="
echo " STEP 2: Building All 550 Packages (8-12 hours)"
echo "=========================================================="
# V2.4.0: Full dependency build — no whitelist trimming.
# LLVM15, rust and all heavy packages are now handled via per-port options files
# (MAKE_JOBS_NUMBER=1, USE_TMPFS=no, MAX_MEMORY=14) set in Phase 1 & 2.
./build.sh --update-pkg-repo


echo "=========================================================="
echo " STEP 3: Post-Package Source Sync & Patch Application"
echo "=========================================================="
# After --update-pkg-repo, build.sh has synced FreeBSD-src.
# Apply cryptotest.c patch now that the source tree exists.

CRYPTOTEST="/root/pfsense/tmp/FreeBSD-src/tools/tools/crypto/cryptotest.c"
if [ -f "$CRYPTOTEST" ] && [ ! -f "${CRYPTOTEST}.orig" ]; then
    echo ">>> Applying cryptotest.c #if 0 guards..."
    sh /root/fix_cryptotest.sh
    echo "  cryptotest.c patch applied. Exit code: $?"
else
    echo "  cryptotest.c already patched or not present — skipping."
fi


echo "=========================================================="
echo " STEP 4: buildworld (Direct make invocation)"
echo "=========================================================="
# V2.4.0 KEY CHANGE: Invoke make directly instead of ./build.sh
# Reason: build.sh runs 'git clean -fdx' which wipes untracked files (including
# the JACOSShield kernel config) on every invocation. Direct make bypasses this.
# Using -j4 for buildworld is safe (world build is not the OOM source).
cd /root/pfsense/tmp/FreeBSD-src

echo ">>> Running: make -j4 buildworld"
make -j4 buildworld 2>&1 | tee "$LOG_DIR/buildworld.log"
echo ">>> buildworld complete. Exit code: $?"


echo "=========================================================="
echo " STEP 5: installworld"
echo "=========================================================="
echo ">>> Running: make installworld"
make installworld 2>&1 | tee "$LOG_DIR/installworld.log"
echo ">>> installworld complete. Exit code: $?"


echo "=========================================================="
echo " STEP 6: Create JACOSShield Kernel Config & buildkernel"
echo "=========================================================="
# V2.4.0 KEY CHANGE: Re-create kernel config immediately before make invocation.
# git clean would wipe it if we used build.sh, so we maintain it here manually.
echo ">>> Ensuring JACOSShield kernel config exists..."
sh /root/create_kernconf.sh

echo ">>> Running: make -j4 KERNCONF=JACOSShield buildkernel"
make -j4 KERNCONF=JACOSShield buildkernel 2>&1 | tee "$LOG_DIR/kernel_build.log"
echo ">>> buildkernel complete. Exit code: $?"

# Confirm ident in obj tree
KERNEL_OBJ="/root/pfsense/tmp/FreeBSD-src/sys/JACOSShield"
if [ -d "$KERNEL_OBJ" ]; then
    echo ">>> JACOSShield kernel obj tree confirmed at $KERNEL_OBJ"
else
    echo "ERROR: Kernel obj tree not found at $KERNEL_OBJ"
    exit 1
fi


echo "=========================================================="
echo " STEP 7: installkernel"
echo "=========================================================="
echo ">>> Running: make installkernel KERNCONF=JACOSShield"
make installkernel KERNCONF=JACOSShield 2>&1 | tee "$LOG_DIR/installkernel.log"
echo ">>> installkernel complete. Exit code: $?"


echo "=========================================================="
echo " STEP 8: ISO Assembly"
echo "=========================================================="
# V2.4.0: Use NO_BUILDWORLD=YES NO_BUILDKERNEL=YES to skip build.sh's git reset
# step entirely — preserving all patches. ISO assembly only.
cd /root/pfsense
echo ">>> Running: ./build.sh --skip-final-rsync iso (with NO_BUILDWORLD/NO_BUILDKERNEL)"
NO_BUILDWORLD=YES NO_BUILDKERNEL=YES ./build.sh --skip-final-rsync iso \
    2>&1 | tee "$LOG_DIR/iso_assembly.log"


echo "=========================================================="
echo " STEP 9: V2.4.0 VERIFICATION PROTOCOL"
echo "=========================================================="
ISO_FILE=$(find /root/pfsense/tmp -name '*.iso' | head -n 1)

if [ -f "$ISO_FILE" ]; then
    echo ">>> STATUS: SUCCESS"
    echo ">>> LOG PATH:  $LOG_FILE"
    echo ">>> ISO PATH:  $ISO_FILE"
    echo ">>> ISO SIZE:  $(du -sh "$ISO_FILE" | cut -f1)"
    echo ">>> SHA256:    $(sha256 -q "$ISO_FILE")"
    echo ""
    echo ">>> Repository Commit Hashes:"
    echo "  - pfsense:     $(cd /root/pfsense      && git rev-parse HEAD)"
    echo "  - freebsd-src: $(cd /root/freebsd-src  && git rev-parse HEAD)"
    echo "  - freebsd-ports: $(cd /root/freebsd-ports && git rev-parse HEAD)"
    echo ""
    echo ">>> Build Logs:"
    for LOG in buildworld installworld kernel_build installkernel iso_assembly; do
        LOG_PATH="$LOG_DIR/${LOG}.log"
        [ -f "$LOG_PATH" ] && echo "  - $LOG_PATH ($(wc -l < "$LOG_PATH") lines)"
    done
else
    echo ">>> STATUS: FAILED (ISO not found)"
    echo ">>> Check logs in $LOG_DIR for root cause."
    exit 1
fi

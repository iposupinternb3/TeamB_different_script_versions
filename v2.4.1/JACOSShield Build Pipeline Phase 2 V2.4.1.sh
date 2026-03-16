#!/usr/local/bin/bash

# ==============================================================================
# JACOSShield Build Pipeline: Phase 2 V2.4.0
# Target: FreeBSD 14.0-RELEASE (VirtualBox/VMware VM)
#

set -e
LOG_FILE="/root/logs/v2.4.0/phase2_patching.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo ">>> Starting Phase 2 V2.4.0: Source Patching & Package Configuration"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root."
    exit 1
fi


# ── 1. Generate build.conf ─────────────────────────────────────────────────────
# V2.4.0: MAKE_JOBS, PARALLEL_JOBS, KERNEL_JOBS, POUDRIERE_JOBS all set to 1
# to prevent llvm15+rust simultaneous OOM SIGKILL cascades.
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
export MAKE_JOBS=1
export PARALLEL_JOBS=1
export KERNEL_JOBS=1
export POUDRIERE_JOBS=1
export POUDRIERE_PORTS_NAME="JACOSShield_v2_7_2"
EOF


# ── 2. Fix Parallelism in builder_common.sh ────────────────────────────────────
echo ">>> Patching builder_common.sh parallelism..."
sed -i '' 's/local _parallel_jobs=.*/local _parallel_jobs=1/g' /root/pfsense/tools/builder_common.sh
sed -i '' 's/_parallel_jobs=$((.*/_parallel_jobs=1/g' /root/pfsense/tools/builder_common.sh
sed -i '' 's/PARALLEL_JOBS=${_parallel_jobs}/PARALLEL_JOBS=1/g' /root/pfsense/tools/builder_common.sh


# ── 3. Suppress lib32 (Fixes aes-586.S assembly crash) ────────────────────────
mkdir -p /usr/local/etc/poudriere.d/
cat << 'EOF' > /usr/local/etc/poudriere.d/JACOSShield_v2_7_2_amd64-src.conf
WITHOUT_LIB32=yes
WITHOUT_TESTS=yes
WITHOUT_CLANG_EXTRAS=yes
EOF
echo -e "WITHOUT_LIB32=yes\nWITHOUT_TESTS=yes" > /etc/src.conf

# Patch jail.sh buildworld call to include WITHOUT_LIB32
sed -i '' 's/${MAKEWORLDARGS} || err 1 "Failed to '"'"'make buildworld'"'"'"/${MAKEWORLDARGS} WITHOUT_LIB32=yes WITHOUT_TESTS=yes || err 1 "Failed to '"'"'make buildworld'"'"'"/g' \
    /usr/local/share/poudriere/jail.sh


# ── 4. Fix Poudriere Ports Name ────────────────────────────────────────────────
sed -i '' 's/export POUDRIERE_PORTS_NAME=.*/export POUDRIERE_PORTS_NAME="JACOSShield_v2_7_2"/g' \
    /root/pfsense/tools/builder_defaults.sh


# ── 5. Brotli: Remove bad patch hash AND PATCHFILES from both locations ────────
# V2.4.0 only patched /root/freebsd-ports. Poudriere uses its own internal copy.
# V2.4.0 patches both to prevent the SHA256 fetch failure on every run.
echo ">>> Fixing brotli distinfo and Makefile in both ports tree locations..."

BROTLI_PORTS="/root/freebsd-ports/archivers/brotli"
BROTLI_POUDRIERE="/usr/local/poudriere/ports/JACOSShield_v2_7_2/archivers/brotli"

for BROTLI_DIR in "$BROTLI_PORTS" "$BROTLI_POUDRIERE"; do
    if [ -d "$BROTLI_DIR" ]; then
        # Remove the bad hash line from distinfo
        sed -i '' '/741610efd335a8b6ff9be4c9bed643e0a74fdb6a/d' "$BROTLI_DIR/distinfo"
        # Remove PATCHFILES directive from Makefile (prevents fetch size mismatch)
        sed -i '' '/^PATCHFILES/d' "$BROTLI_DIR/Makefile"
        echo "  Patched: $BROTLI_DIR"
    fi
done


# ── 6. LLVM15: Inject memory-saving options ────────────────────────────────────
# V2.4.0 NEW: Reduces peak RAM from 8-12GB to manageable levels.
# MAKE_JOBS_NUMBER=1 prevents parallel C++ compilation OOM.
# CXXFLAGS -O1 -g0 reduces memory vs default -O2 -g.
echo ">>> Configuring llvm15 memory options..."
LLVM15_MK="/usr/local/poudriere/ports/JACOSShield_v2_7_2/devel/llvm15/Makefile"
if [ -f "$LLVM15_MK" ]; then
    # Only append if not already present (idempotent)
    if ! grep -q "MAKE_JOBS_NUMBER=1" "$LLVM15_MK"; then
        echo "" >> "$LLVM15_MK"
        echo "MAKE_JOBS_NUMBER=1" >> "$LLVM15_MK"
        echo "CXXFLAGS+=-O1 -g0" >> "$LLVM15_MK"
    fi
fi

# llvm15 options: disable LTO, LLDB, DOCS, MANPAGES, GOLD, MLIR, POLLY
LLVM15_OPT_DIR="/usr/local/etc/poudriere.d/JACOSShield_v2_7_2-options"
mkdir -p "$LLVM15_OPT_DIR"
cat << 'EOF' > "$LLVM15_OPT_DIR/devel_llvm15"
OPTIONS_FILE_UNSET+=LTO
OPTIONS_FILE_UNSET+=LLDB
OPTIONS_FILE_UNSET+=DOCS
OPTIONS_FILE_UNSET+=MANPAGES
OPTIONS_FILE_UNSET+=GOLD
OPTIONS_FILE_UNSET+=MLIR
OPTIONS_FILE_UNSET+=POLLY
EOF


# ── 7. Rust: Inject memory-saving options ──────────────────────────────────────
# V2.4.0 NEW: MAKE_JOBS_NUMBER=1 prevents embed-bitcode tmpfs exhaustion.
echo ">>> Configuring rust memory options..."
RUST_MK="/usr/local/poudriere/ports/JACOSShield_v2_7_2/lang/rust/Makefile"
if [ -f "$RUST_MK" ]; then
    if ! grep -q "MAKE_JOBS_NUMBER=1" "$RUST_MK"; then
        echo "" >> "$RUST_MK"
        echo "MAKE_JOBS_NUMBER=1" >> "$RUST_MK"
    fi
fi

cat << 'EOF' > "$LLVM15_OPT_DIR/lang_rust"
OPTIONS_FILE_UNSET+=DOCS
OPTIONS_FILE_UNSET+=SOURCES
OPTIONS_FILE_UNSET+=RUSTFMT
OPTIONS_FILE_UNSET+=ANALYSIS
OPTIONS_FILE_UNSET+=GDB
EOF


# ── 8. OpenVPN: Disable TEST via options file (NO Makefile sed) ────────────────
# V2.4.0 used sed on Makefile which accidentally wiped it to 0 bytes.
# V2.4.0 uses only the options file approach - safe, no Makefile touch.
echo ">>> Disabling OpenVPN test suite via options file..."
cat << 'EOF' > "$LLVM15_OPT_DIR/security_openvpn"
OPTIONS_FILE_UNSET+=TEST
EOF


# ── 9. repoc: Rewrite as NO_FETCH/NO_BUILD stub ────────────────────────────────
# V2.4.0 NEW: Port fetches from inaccessible private Netgate GitLab.
# Rewritten as a complete stub that installs shell script placeholders.
# DISTFILES is set to completely blank (no comment) to avoid literal parsing.
echo ">>> Rewriting JACOSShield-repoc as NO_FETCH stub..."
REPOC_DIR="/usr/local/poudriere/ports/JACOSShield_v2_7_2/sysutils/JACOSShield-repoc"
if [ -d "$REPOC_DIR" ]; then
    # Write new Makefile (tab-indented, DISTFILES blank)
    cat > "$REPOC_DIR/Makefile" << 'REPOCEOF'
PORTNAME=	JACOSShield-repoc
PORTVERSION=	20230912
CATEGORIES=	sysutils

MAINTAINER=	intern@example.com
COMMENT=	JACOSShield repoc stub

NO_FETCH=	yes
NO_BUILD=	yes

DISTFILES=

do-install:
	${MKDIR} ${STAGEDIR}${PREFIX}/sbin
	${INSTALL_SCRIPT} ${FILESDIR}/JACOSShield-repoc.sh ${STAGEDIR}${PREFIX}/sbin/JACOSShield-repoc

.include <bsd.port.mk>
REPOCEOF

    mkdir -p "$REPOC_DIR/files"
    cat << 'STUBEOF' > "$REPOC_DIR/files/JACOSShield-repoc.sh"
#!/bin/sh
# JACOSShield-repoc stub
exit 0
STUBEOF
    chmod +x "$REPOC_DIR/files/JACOSShield-repoc.sh"
fi

# Also remove repoc dependency from pfSense-upgrade Makefile in both locations
sed -i '' '/pfSense-repoc/d' /root/freebsd-ports/sysutils/pfSense-upgrade/Makefile 2>/dev/null || true
UPGRADE_MK="/usr/local/poudriere/ports/JACOSShield_v2_7_2/sysutils/pfSense-upgrade/Makefile"
[ -f "$UPGRADE_MK" ] && sed -i '' '/pfSense-repoc/d' "$UPGRADE_MK"


# ── 10. php-JACOSShield-module: Fix missing headers ────────────────────────────
# V2.4.0 NEW: pfSense_private.h did not exist in files/ — only JACOSShield_private.h.
# Fix: create pfSense_private.h and add explicit cp lines in extract target.
echo ">>> Fixing php-JACOSShield-module missing header files..."
PHP_MOD_DIR="/usr/local/poudriere/ports/JACOSShield_v2_7_2/devel/php-JACOSShield-module"
if [ -d "$PHP_MOD_DIR/files" ]; then
    # Create pfSense_private.h from JACOSShield_private.h if missing
    if [ ! -f "$PHP_MOD_DIR/files/pfSense_private.h" ] && \
       [ -f "$PHP_MOD_DIR/files/JACOSShield_private.h" ]; then
        cp "$PHP_MOD_DIR/files/JACOSShield_private.h" "$PHP_MOD_DIR/files/pfSense_private.h"
        echo "  Created pfSense_private.h"
    fi

    # Inject explicit cp lines into extract target if not already present
    MK="$PHP_MOD_DIR/Makefile"
    if [ -f "$MK" ] && ! grep -q "pfSense_arginfo.h" "$MK"; then
        # Use Python for safe Makefile editing (avoids sed 0-byte wipe risk)
        python3 << PYEOF
import re, sys

with open("$MK", "r") as f:
    content = f.read()

insert = """\\tcp \${FILESDIR}/pfSense_arginfo.h \${WRKSRC}/
\tcp \${FILESDIR}/pfSense_private.h \${WRKSRC}/
"""

# Insert after do-extract: target line
content = re.sub(
    r'(do-extract:\n\t)',
    r'\1' + insert.replace('\\', '\\\\'),
    content
)

with open("$MK", "w") as f:
    f.write(content)

print("  Injected explicit header copy lines into extract target")
PYEOF
    fi
fi


# ── 11. JACOSShield@php82: Fix fetch URL, WRKSRC and plist ────────────────────
# V2.4.0 NEW: Three layered fixes for the JACOSShield@php82 port.
#   Fix 1: Set PFSENSE_COMMITHASH, PRODUCT_VERSION, PFSENSE_DATESTRING in make.conf
#          so the fetch URL does not collapse to JACOSShield-v.tar.bz2
#   Fix 2: DISTVERSION hardcoded; WRKSRC set to match tarball internal dir
#   Fix 3: PLIST= added to enable automatic plist generation (no static pkg-plist needed)
echo ">>> Fixing JACOSShield@php82 port..."

MAKE_CONF="/usr/local/etc/poudriere.d/JACOSShield_v2_7_2-make.conf"
mkdir -p "$(dirname "$MAKE_CONF")"

if ! grep -q "PFSENSE_COMMITHASH" "$MAKE_CONF" 2>/dev/null; then
    cat << 'EOF' >> "$MAKE_CONF"
PFSENSE_COMMITHASH=ec956d343e6cd2db69caa23ba647a19d18fdbc3a
PRODUCT_VERSION=2.7.2-RELEASE
PFSENSE_DATESTRING=2026-03-10
EOF
fi

JACOS_PHP82_DIR="/usr/local/poudriere/ports/JACOSShield_v2_7_2/security/JACOSShield@php82"
if [ -d "$JACOS_PHP82_DIR" ]; then
    MK="$JACOS_PHP82_DIR/Makefile"
    if [ -f "$MK" ]; then
        # Fix 2: Hardcode DISTVERSION and correct WRKSRC
        if ! grep -q "DISTVERSION=2.7.2-RELEASE" "$MK"; then
            sed -i '' 's/^DISTVERSION=.*/DISTVERSION=2.7.2-RELEASE/' "$MK"
        fi
        if ! grep -q "^WRKSRC=" "$MK"; then
            sed -i '' '/^DISTVERSION/a\
WRKSRC=\t${WRKDIR}/JACOSShield-v2.7.2-RELEASE
' "$MK"
        fi

        # Fix 3: Add PLIST= above .include <bsd.port.pre.mk> for auto plist generation
        if ! grep -q "^PLIST=" "$MK"; then
            sed -i '' 's/^\.include <bsd\.port\.pre\.mk>/PLIST=\
.include <bsd.port.pre.mk>/' "$MK"
        fi
    fi
fi


# ── 12. Build the JACOSShield@php82 tarball locally ───────────────────────────
# Netgate GitLab is inaccessible. We build the tarball from the local pfsense
# git checkout, then drop it into the distfiles cache.
echo ">>> Building JACOSShield@php82 local tarball from /root/pfsense..."
DISTFILES_DIR="/usr/ports/distfiles"
TARBALL="$DISTFILES_DIR/JACOSShield-v2.7.2-RELEASE.tar.bz2"

if [ ! -f "$TARBALL" ]; then
    TMPBUILD=$(mktemp -d)
    ln -s /root/pfsense "$TMPBUILD/JACOSShield-v2.7.2-RELEASE"
    tar -C "$TMPBUILD" -hcjf "$TARBALL" JACOSShield-v2.7.2-RELEASE \
        --exclude='.git' 2>/dev/null
    rm -rf "$TMPBUILD"
    echo "  Tarball created: $TARBALL ($(du -sh "$TARBALL" | cut -f1))"
else
    echo "  Tarball already present: $TARBALL"
fi


# ── 13. cryptotest.c: Apply #if 0 guards for removed FreeBSD struct members ────
# V2.4.0 NEW: cryptotest.c references struct cryptotstat members removed in newer
# FreeBSD. Guards the three affected code blocks to allow clean compilation.
echo ">>> Patching cryptotest.c with #if 0 guards..."
CRYPTOTEST="/root/pfsense/tmp/FreeBSD-src/tools/tools/crypto/cryptotest.c"

if [ -f "$CRYPTOTEST" ]; then
    cat > /tmp/fix_cryptotest.py << 'PYEOF'
import re, shutil, sys

src = sys.argv[1]
shutil.copy(src, src + ".orig")

with open(src, "r") as f:
    lines = f.readlines()

out = []
i = 0
while i < len(lines):
    line = lines[i]
    # Guard 1: bzero/min.tv_sec block (~line 421-429)
    if "bzero(&top->cs_invoke" in line or "min.tv_sec" in line:
        out.append("#if 0  /* V2.4.0: removed struct cryptotstat members */\n")
        while i < len(lines) and "}" not in lines[i]:
            out.append(lines[i])
            i += 1
        if i < len(lines):
            out.append(lines[i])
            i += 1
        out.append("#endif\n")
        continue
    # Guard 2: printt() function (~line 435-446)
    if re.match(r'^static void\s+printt\s*\(', line):
        out.append("#if 0  /* V2.4.0: removed struct cryptotstat members */\n")
        brace = 0
        while i < len(lines):
            out.append(lines[i])
            brace += lines[i].count("{") - lines[i].count("}")
            i += 1
            if brace == 0 and i > 0:
                break
        out.append("#endif\n")
        continue
    # Guard 3: cs_invoke.count block (~line 529-530)
    if "cs_invoke.count" in line or "cs_done.count" in line:
        out.append("#if 0  /* V2.4.0: removed struct cryptotstat members */\n")
        out.append(line)
        i += 1
        if i < len(lines) and lines[i].strip().startswith("top->cs"):
            out.append(lines[i])
            i += 1
        out.append("#endif\n")
        continue
    out.append(line)
    i += 1

with open(src, "w") as f:
    f.writelines(out)
print("cryptotest.c patched successfully.")
PYEOF
    python3 /tmp/fix_cryptotest.py "$CRYPTOTEST"
else
    echo "  WARNING: cryptotest.c not found at $CRYPTOTEST"
    echo "  This is expected if FreeBSD-src has not been extracted yet by build.sh."
    echo "  Phase 3 will re-apply this patch before buildworld if needed."

    # Install fix script so Phase 3 can call it post-source-sync
    cat > /root/fix_cryptotest.sh << 'FIXEOF'
#!/bin/sh
CRYPTOTEST="/root/pfsense/tmp/FreeBSD-src/tools/tools/crypto/cryptotest.c"
[ ! -f "$CRYPTOTEST" ] && echo "cryptotest.c not found, skipping." && exit 0
python3 /tmp/fix_cryptotest.py "$CRYPTOTEST"
FIXEOF
    chmod +x /root/fix_cryptotest.sh
    echo "  Saved /root/fix_cryptotest.sh for Phase 3 to invoke post-sync."
fi


# ── 14. JACOSShield Kernel Config ──────────────────────────────────────────────
# V2.4.0 NEW: build.sh derives KERNCONF from PRODUCT_NAME=JACOSShield.
# The config must exist at sys/amd64/conf/JACOSShield or every build fails.
# NOTE: build.sh runs git clean which wipes untracked files. Phase 3 re-creates
# this config immediately before direct make invocation (bypassing git reset).
FREEBSD_SRC="/root/pfsense/tmp/FreeBSD-src"
KERNCONF_DIR="$FREEBSD_SRC/sys/amd64/conf"

if [ -d "$KERNCONF_DIR" ]; then
    if [ ! -f "$KERNCONF_DIR/JACOSShield" ]; then
        cp "$KERNCONF_DIR/pfSense" "$KERNCONF_DIR/JACOSShield"
        sed -i '' 's/ident.*pfSense/ident JACOSShield/' "$KERNCONF_DIR/JACOSShield"
        echo "  Created JACOSShield kernel config."
    else
        echo "  JACOSShield kernel config already present."
    fi
else
    echo "  WARNING: FreeBSD-src not yet present at $FREEBSD_SRC"
    echo "  Phase 3 will create the kernel config after build.sh syncs sources."
fi

# Save kernel config creation as a standalone script for Phase 3 to call
cat << 'KCEOF' > /root/create_kernconf.sh
#!/bin/sh
KERNCONF_DIR="/root/pfsense/tmp/FreeBSD-src/sys/amd64/conf"
if [ ! -f "$KERNCONF_DIR/JACOSShield" ]; then
    cp "$KERNCONF_DIR/pfSense" "$KERNCONF_DIR/JACOSShield"
    sed -i '' 's/ident.*pfSense/ident JACOSShield/' "$KERNCONF_DIR/JACOSShield"
    echo "JACOSShield kernel config created."
fi
KCEOF
chmod +x /root/create_kernconf.sh


echo ">>> Phase 2 V2.4.0 Complete. Proceed to Phase 3."

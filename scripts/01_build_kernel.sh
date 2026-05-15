#!/usr/bin/env bash
# scripts/01_build_kernel.sh
set -euo pipefail

KERNEL_TAG="${KERNEL_TAG:-v6.12}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KERNEL_SRC="$WORKSPACE_ROOT/kernel/linux"
BUILD_DIR="$WORKSPACE_ROOT/kernel/build"
JOBS=$(nproc)

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

echo -e "${CYAN}[1/5] Clonando kernel ${KERNEL_TAG}...${NC}"
if [ ! -d "$KERNEL_SRC" ]; then
  git clone --depth 1 --branch "$KERNEL_TAG" https://github.com/torvalds/linux.git "$KERNEL_SRC"
else
  echo -e "${YELLOW}  → Fuentes ya presentes, omitiendo clone.${NC}"
fi

cd "$KERNEL_SRC"
echo ""
echo -e "${CYAN}[2/5] Guardando hash del commit vulnerable (evidencia)...${NC}"
VULN_HASH=$(git rev-parse HEAD)
mkdir -p "$WORKSPACE_ROOT/kernel"
echo "$VULN_HASH" > "$WORKSPACE_ROOT/kernel/vuln_commit.txt"
echo "  Hash: $VULN_HASH"

echo ""
echo -e "${CYAN}[3/5] Configurando el kernel...${NC}"
make tinyconfig

scripts/config --enable 64BIT
scripts/config --enable SERIAL_8250
scripts/config --enable SERIAL_8250_CONSOLE
scripts/config --enable TTY
scripts/config --enable BLK_DEV_INITRD
scripts/config --enable INITRAMFS_SOURCE
scripts/config --enable TMPFS
scripts/config --enable NET
scripts/config --enable UNIX
scripts/config --enable INET
scripts/config --enable CRYPTO
scripts/config --enable CRYPTO_USER_API
scripts/config --enable CRYPTO_USER_API_AEAD
scripts/config --enable CRYPTO_USER_API_SKCIPHER
scripts/config --enable CRYPTO_AUTHENCESN
scripts/config --enable CRYPTO_AES
scripts/config --enable CRYPTO_CBC
scripts/config --enable CRYPTO_HMAC
scripts/config --enable CRYPTO_SHA256
scripts/config --enable MULTIUSER
scripts/config --enable PRINTK
scripts/config --enable EARLY_PRINTK
scripts/config --enable PROC_FS
scripts/config --enable SYSFS
scripts/config --enable DEVTMPFS
scripts/config --enable DEVTMPFS_MOUNT
scripts/config --enable RD_GZIP
scripts/config --enable BINFMT_ELF
scripts/config --enable BINFMT_SCRIPT

make olddefconfig

echo ""
echo -e "${CYAN}[4/5] Compilando kernel con ${JOBS} cores (~15-25 min)...${NC}"
echo -e "${YELLOW}  Tip: abre otra terminal y lee el write-up mientras compila.${NC}"
START=$(date +%s)
make -j"$JOBS" bzImage 2>&1 | tail -5
END=$(date +%s)
echo -e "  Tiempo: $((END - START)) segundos"

mkdir -p "$BUILD_DIR"
cp arch/x86/boot/bzImage "$BUILD_DIR/bzImage_vuln"
echo ""
echo -e "${GREEN}[5/5] ✓ Kernel compilado → kernel/build/bzImage_vuln${NC}"

if grep -q "CONFIG_CRYPTO_USER_API_AEAD=y" .config; then
  echo -e "${GREEN}  ✓ CONFIG_CRYPTO_USER_API_AEAD=y confirmado${NC}"
else
  echo -e "${YELLOW}  ⚠ Verifica CONFIG_CRYPTO_USER_API_AEAD manualmente${NC}"
fi

echo ""
echo -e "  Siguiente paso: ${CYAN}make rootfs${NC}"

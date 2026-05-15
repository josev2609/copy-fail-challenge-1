##!/usr/bin/env bash
# scripts/02_build_rootfs.sh
set -euo pipefail
 
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUSYBOX_SRC="$WORKSPACE_ROOT/kernel/busybox"
INITRAMFS_DIR="$WORKSPACE_ROOT/kernel/initramfs"
BUILD_DIR="$WORKSPACE_ROOT/kernel/build"
JOBS=$(nproc)
 
GREEN='\033[1;32m'
CYAN='\033[1;36m'
NC='\033[0m'
 
mkdir -p "$BUILD_DIR"
mkdir -p "$INITRAMFS_DIR"
 
# ─────────────────────────────────────────────
echo -e "${CYAN}[1/6] Preparando BusyBox...${NC}"
# ─────────────────────────────────────────────
if [ ! -d "$BUSYBOX_SRC" ]; then
    git clone --depth 1 https://git.busybox.net/busybox "$BUSYBOX_SRC"
fi
 
cd "$BUSYBOX_SRC"
make defconfig
 
# FIX 1: La línea original falla si CONFIG_STATIC ya existe en otra forma.
# Usamos una sustitución más robusta que cubre todos los casos.
sed -i 's/.*CONFIG_STATIC.*/CONFIG_STATIC=y/' .config
 
make -j"$JOBS" install CONFIG_PREFIX="$INITRAMFS_DIR" > /dev/null
 
# ─────────────────────────────────────────────
echo -e "${CYAN}[2/6] Estructura de directorios...${NC}"
# ─────────────────────────────────────────────
mkdir -p "$INITRAMFS_DIR"/{proc,sys,dev,tmp,etc,root,home/student,usr/bin,run,sbin,usr/sbin}
 
# FIX 2: Crear dev/console como nodo de dispositivo real.
# Sin esto el kernel lanza error -2 incluso si /init existe correctamente.
# El montaje de devtmpfs en el init no ocurre hasta DESPUÉS de que el kernel
# ya intentó abrir /dev/console para la consola del init.
if [ ! -c "$INITRAMFS_DIR/dev/console" ]; then
    mknod "$INITRAMFS_DIR/dev/console" c 5 1
    chmod 600 "$INITRAMFS_DIR/dev/console"
fi
 
# FIX 3: /dev/null también es necesario para redireccionas durante el boot.
if [ ! -c "$INITRAMFS_DIR/dev/null" ]; then
    mknod "$INITRAMFS_DIR/dev/null" c 1 3
    chmod 666 "$INITRAMFS_DIR/dev/null"
fi
 
# ─────────────────────────────────────────────
echo -e "${CYAN}[3/6] Configurando Usuarios y Grupos...${NC}"
# ─────────────────────────────────────────────
cat > "$INITRAMFS_DIR/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
student:x:1001:1001:student:/home/student:/bin/sh
EOF
 
cat > "$INITRAMFS_DIR/etc/group" << 'EOF'
root:x:0:
student:x:1001:
EOF
 
# ─────────────────────────────────────────────
echo -e "${CYAN}[4/6] Creando script /init...${NC}"
# ─────────────────────────────────────────────
cat > "$INITRAMFS_DIR/init" << 'EOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
 
# FIX 4 (en el init): devtmpfs puede no estar disponible en kernels mínimos.
# Intentamos devtmpfs primero, luego tmpfs + mdev como fallback.
mount -t devtmpfs devtmpfs /dev 2>/dev/null || {
    mount -t tmpfs tmpfs /dev
    mdev -s
}
 
mount -t tmpfs none /tmp
 
modprobe algif_aead 2>/dev/null || true
 
echo "  KERNEL VULNERABLE LAB - INICIANDO..."
hostname "linux-lab-challenge"
 
chown -R 1001:1001 /home/student
 
exec su - student
EOF
 
# Eliminar CRLF y dar permisos
sed -i 's/\r$//' "$INITRAMFS_DIR/init"
chmod 755 "$INITRAMFS_DIR/init"
 
# ─────────────────────────────────────────────
echo -e "${CYAN}[5/6] Configurando Perfil de Usuario...${NC}"
# ─────────────────────────────────────────────
cat > "$INITRAMFS_DIR/etc/profile" << 'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PS1='[\u@lab \w]\$ '
alias ll='ls -la'
echo "Bienvenido, estas logueado como: $(id)"
EOF
sed -i 's/\r$//' "$INITRAMFS_DIR/etc/profile"
 
# ─────────────────────────────────────────────
echo -e "${CYAN}[6/6] Empaquetando initramfs...${NC}"
# ─────────────────────────────────────────────
cd "$INITRAMFS_DIR"
 
# FIX 5: Symlink con target RELATIVO (no absoluto).
# "/bin/busybox" como target absoluto puede fallar en el initramfs
# si el rootfs no está todavía montado cuando se resuelve el symlink.
ln -sf busybox bin/sh 2>/dev/null || true
 
# FIX 6: Quitar el flag -v (verbose) del cpio. No rompe nada, pero
# mezcla el listado de archivos con el stream binario si hay algún
# pipe intermedio mal configurado. Más limpio sin él.
# FIX 7: El comando correcto — find desde "." dentro de INITRAMFS_DIR
# para que las rutas en el cpio sean "./init", "./bin/sh", etc. (raíz real).
find . -print0 | cpio --null --create --format=newc | gzip -9 > "$BUILD_DIR/initramfs.cpio.gz"
 
# VERIFICACIÓN AUTOMÁTICA: confirmar que init está en la raíz del cpio
echo -e "${CYAN}Verificando estructura del initramfs:${NC}"
CPIO_LIST=$(zcat "$BUILD_DIR/initramfs.cpio.gz" | cpio --list 2>/dev/null)
 
if echo "$CPIO_LIST" | grep -qE "^\./init$|^init$"; then
    echo -e "${GREEN}✓ /init encontrado en la raíz del initramfs${NC}"
else
    echo -e "\033[1;31m✗ ERROR: /init NO está en la raíz. Rutas encontradas:${NC}"
    echo "$CPIO_LIST" | grep -i init || echo "(ninguna)"
    exit 1
fi
 
if echo "$CPIO_LIST" | grep -qE "^\./bin/sh$|^bin/sh$"; then
    echo -e "${GREEN}✓ bin/sh symlink presente${NC}"
else
    echo -e "\033[1;31m✗ ADVERTENCIA: bin/sh no encontrado en el initramfs${NC}"
fi
 
echo -e "${GREEN}✓ Proceso completado exitosamente.${NC}"

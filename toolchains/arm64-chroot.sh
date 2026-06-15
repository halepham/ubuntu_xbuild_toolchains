#!/bin/bash
# -----------------------------------------------------------------------------
# Description:
#   This script provides a chroot environment for the ARM64 sysroot.
#   It mounts necessary filesystems and uses QEMU for ARM64 emulation.
# Input Arguments:
#   All arguments are passed to the chroot command.
# -----------------------------------------------------------------------------

set -e

LOCKFILE="/tmp/arm64-chroot.lock"

# Check for existing lock
if [ -f "$LOCKFILE" ]; then
    PID=$(cat "$LOCKFILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Another arm64-chroot instance is running (PID: $PID)"
        echo "Wait for it to finish or kill it with: sudo kill $PID"
        exit 1
    else
        echo "Removing stale lock file"
        sudo rm -f "$LOCKFILE"
    fi
fi

# Create lock
echo $$ | sudo tee "$LOCKFILE" > /dev/null

cleanup() {
    echo "Cleaning up..."
    sudo umount -l $ARM64_SYSROOT/proc 2>/dev/null || true
    sudo umount -l $ARM64_SYSROOT/sys 2>/dev/null || true
    sudo umount -l $ARM64_SYSROOT/dev 2>/dev/null || true

    # Sync after unmount
	sync
    sudo rm -f "$LOCKFILE"
    echo "Cleanning up completed successfully."
}

trap cleanup EXIT INT TERM

mount_chroot() {
    echo "Mounting filesystems..."
    sudo mount -t proc proc $ARM64_SYSROOT/proc 2>/dev/null || true
    sudo mount -t sysfs sysfs $ARM64_SYSROOT/sys 2>/dev/null || true
    sudo mount -o bind /dev $ARM64_SYSROOT/dev 2>/dev/null || true

    echo "Mount chroot completed successfully."
}

# Set non-interactive environment
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

mount_chroot
sudo update-binfmts --enable qemu-aarch64 2>/dev/null || true
echo "Entering ARM64 chroot environment..."
echo -e "\033[32mExecuting command: \033[36msudo $@\033[0m"
sudo chroot $ARM64_SYSROOT "$@"
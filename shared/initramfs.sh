#!/usr/bin/env bash

set -xeuo pipefail

mkdir -p /usr/lib/dracut/dracut.conf.d/

# Fix dracut's unit search paths on Debian/Ubuntu — upstream dracut assumes
# Fedora layout; Ubuntu puts systemd units under /usr/lib/systemd/system.
printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" \
    | tee /usr/lib/dracut/dracut.conf.d/30-ubuntu-bootc-fix-paths.conf

# Build a generic, reproducible initramfs with the bootc module.
# hostonly=no  — works on any machine (required for OTA-updated images).
# compress=zstd — fast decompression on boot.
printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" bootc "\n' \
    | tee /usr/lib/dracut/dracut.conf.d/30-ubuntu-bootc-container-build.conf

# Auto-detect the installed kernel version; skip any .img files that dracut
# may have left in /usr/lib/modules from a prior run.
KVER_DIR="$(find /usr/lib/modules -maxdepth 1 -type d | grep -vE '\.img$' | tail -n 1)"
dracut --force "${KVER_DIR}/initramfs.img"

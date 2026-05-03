# List available commands
[group('info')]
default:
    @just --list

# ── Configuration ──────────────────────────────────────────────────────────────
image_name := env("BUILD_IMAGE_NAME", "")
image_tag  := env("BUILD_IMAGE_TAG",  "latest")
base_dir   := env("BUILD_BASE_DIR",   ".")
filesystem := env("BUILD_FILESYSTEM", "xfs")
selinux    := env("BUILD_SELINUX",    "true")
vm_ram     := env("VM_RAM",  "4096")
vm_cpus    := env("VM_CPUS", "2")

options := if selinux == "true" {
    "-v /var/lib/containers:/var/lib/containers:Z \
     -v /etc/containers:/etc/containers:Z \
     -v /sys/fs/selinux:/sys/fs/selinux \
     --security-opt label=type:unconfined_t"
} else {
    "-v /var/lib/containers:/var/lib/containers \
     -v /etc/containers:/etc/containers"
}

container_runtime := env(
    "CONTAINER_RUNTIME",
    `command -v podman >/dev/null 2>&1 && echo podman || echo docker`
)

# Use sudo unless already root (CI runners are root)
sudo_cmd := if `id -u` == "0" { "" } else { "sudo" }

# ── Build ──────────────────────────────────────────────────────────────────────

# Build the bootc container image for the given target (e.g. `just build ubuntu`)
[group('build')]
build $image_name=image_name:
    {{sudo_cmd}} {{container_runtime}} build \
        --security-opt label=type:unconfined_t \
        --network=host \
        -f {{image_name}}/Containerfile \
        -t "${image_name}-bootc:latest" .

# Re-chunk image for efficient OCI distribution
[group('build')]
rechunk $image_name=image_name:
    #!/usr/bin/env bash
    set -euo pipefail
    export CHUNKAH_CONFIG_STR="$({{sudo_cmd}} {{container_runtime}} inspect "${image_name}-bootc")"
    {{sudo_cmd}} {{container_runtime}} run --rm \
        "--mount=type=image,src=${image_name}-bootc,dest=/chunkah" \
        -e CHUNKAH_CONFIG_STR \
        quay.io/coreos/chunkah build \
            --label ostree.bootable=1 \
            --compressed \
            --max-layers 128 \
        | {{sudo_cmd}} {{container_runtime}} load \
        | sort -n | head -n1 | cut -d, -f2 | cut -d: -f3 \
        | xargs -I{} {{sudo_cmd}} {{container_runtime}} tag {} "${image_name}-bootc"

# ── Development helpers ────────────────────────────────────────────────────────

# Run bootc inside the built container
[group('dev')]
bootc $image_name=image_name $image_tag=image_tag *ARGS:
    {{sudo_cmd}} {{container_runtime}} run \
        --rm --privileged --pid=host \
        -it \
        {{options}} \
        -v /dev:/dev \
        -e RUST_LOG=debug \
        -v "{{base_dir}}:/data" \
        "${image_name}-bootc:${image_tag}" bootc {{ARGS}}

# ── Test ───────────────────────────────────────────────────────────────────────

# Create a bootable raw disk image via bootc install to-disk
[group('test')]
generate-bootable-image $image_name=image_name $image_tag=image_tag $base_dir=base_dir $filesystem=filesystem:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! {{sudo_cmd}} {{container_runtime}} image exists "${image_name}-bootc:${image_tag}"; then
        echo "ERROR: image '${image_name}-bootc:${image_tag}' not found — run 'just build ${image_name}' first." >&2
        exit 1
    fi
    if [ ! -e "${base_dir}/bootable.raw" ]; then
        echo "==> Creating 20G disk image at ${base_dir}/bootable.raw ..."
        fallocate -l 20G "${base_dir}/bootable.raw"
    fi
    echo "==> Installing ${image_name}-bootc:${image_tag} to disk image ..."
    just bootc "${image_name}" "${image_tag}" install to-disk \
        --via-loopback /data/bootable.raw \
        --filesystem "${filesystem}" \
        --wipe \
        --composefs-backend \
        --bootloader systemd \
        --karg systemd.firstboot=no \
        --karg quiet \
        --karg console=tty0 \
        --karg "console=ttyS0,115200" \
        --karg systemd.debug_shell=ttyS1
    echo "==> Done: ${base_dir}/bootable.raw"
    sync

# Headless boot smoke test — verifies the disk image reaches a login prompt.
# Used for local e2e validation before pushing changes.
[group('test')]
test-boot $image_name=image_name $base_dir=base_dir:
    #!/usr/bin/env bash
    set -euo pipefail
    DISK=$(realpath "${base_dir}/bootable.raw")
    [[ -f "$DISK" ]] || { echo "ERROR: $DISK not found — run 'just generate-bootable-image ${image_name}' first." >&2; exit 1; }

    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm \
               /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }

    OVMF_CODE=""
    for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF not found — install ovmf or edk2-ovmf" >&2; exit 1; }

    SERIAL_LOG=$(mktemp /tmp/ubuntu-bootc-boot-XXXX.log)
    TIMEOUT=240
    echo "=== Boot smoke test: ${DISK} ==="
    echo "    OVMF:    ${OVMF_CODE}"
    echo "    Log:     ${SERIAL_LOG}"
    echo "    Timeout: ${TIMEOUT}s"
    echo ""

    {{sudo_cmd}} "$QEMU" \
        -enable-kvm -m "{{vm_ram}}" -cpu host -smp "{{vm_cpus}}" \
        -display none \
        -drive "file=${DISK},format=raw,if=virtio" \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -device "virtio-net-pci,netdev=net0" \
        -netdev "user,id=net0" \
        -serial "file:${SERIAL_LOG}" \
        -no-reboot &
    QEMU_PID=$!

    ELAPSED=0
    while (( ELAPSED < TIMEOUT )); do
        if grep -qE "login:|Reached target.*(multi-user|graphical)" "${SERIAL_LOG}" 2>/dev/null; then
            {{sudo_cmd}} kill "${QEMU_PID}" 2>/dev/null || true
            wait "${QEMU_PID}" 2>/dev/null || true
            echo ""
            echo "=== PASSED: boot success after ${ELAPSED}s ==="
            CRIT=$(grep -E '\[FAILED\] Failed to start|Kernel panic' "${SERIAL_LOG}" || true)
            [[ -n "$CRIT" ]] && echo "WARNING: critical errors in serial log:" && echo "$CRIT"
            exit 0
        fi
        sleep 2; (( ELAPSED += 2 ))
        printf "."
    done
    echo ""
    echo "=== FAILED: timeout after ${TIMEOUT}s ==="
    echo "--- last 50 lines of serial log ---"
    tail -50 "${SERIAL_LOG}" 2>/dev/null || true
    {{sudo_cmd}} kill "${QEMU_PID}" 2>/dev/null || true
    exit 1

# Boot the disk image interactively in QEMU (GTK, SSH on :2222)
[group('test')]
boot-vm $image_name=image_name $base_dir=base_dir:
    #!/usr/bin/env bash
    set -euo pipefail
    DISK=$(realpath "${base_dir}/bootable.raw")
    [[ -f "$DISK" ]] || { echo "ERROR: $DISK not found." >&2; exit 1; }

    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm \
               /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }

    OVMF_CODE=""
    for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF not found" >&2; exit 1; }

    OVMF_VARS="${base_dir}/.ovmf-vars.fd"
    if [ ! -e "$OVMF_VARS" ]; then
        for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
                  /usr/share/edk2/ovmf/OVMF_VARS.fd; do
            [[ -f "$f" ]] && { cp "$f" "$OVMF_VARS"; break; }
        done
    fi

    echo "==> Booting $DISK ({{vm_ram}}M RAM, {{vm_cpus}} CPUs)"
    echo "    SSH: ssh -p 2222 root@127.0.0.1"
    echo "    Ctrl-A C for QEMU monitor"
    echo ""
    {{sudo_cmd}} "$QEMU" \
        -enable-kvm -m "{{vm_ram}}" -cpu host -smp "{{vm_cpus}}" \
        -drive "file=${DISK},format=raw,if=virtio" \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -drive "if=pflash,format=raw,file=${OVMF_VARS}" \
        -device virtio-vga -display gtk \
        -device virtio-keyboard -device virtio-mouse \
        -device "virtio-net-pci,netdev=net0" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22" \
        -chardev "stdio,id=char0,mux=on,signal=off" \
        -serial chardev:char0 -serial chardev:char0 \
        -mon chardev=char0

# Alias kept for backwards compatibility
[group('test')]
disk-image $image_name=image_name $image_tag=image_tag $base_dir=base_dir $filesystem=filesystem:
    just generate-bootable-image {{image_name}} {{image_tag}} {{base_dir}} {{filesystem}}

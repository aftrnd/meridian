#!/usr/bin/env bash
set -euo pipefail

# Boot local meridian-base.img in QEMU, patch Steam runtime prerequisites,
# then cleanly shut down and strip quarantine xattrs.

SANDBOX="${HOME}/Library/Containers/com.meridian.app/Data/Library/Application Support/com.meridian.app/vm"
BASE_IMG="${SANDBOX}/meridian-base.img"
KERNEL="${SANDBOX}/vmlinuz"
INITRD="${SANDBOX}/initrd"
WORK_DIR="/tmp/meridian-steam-patch-$$"
EFI_VARS="${WORK_DIR}/efi-vars.fd"
QEMU_LOG="${WORK_DIR}/qemu.log"
QEMU_PID=""

SSH_PORT=2222
SSH_USER="meridian"
SSH_PASS="meridian"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=no -o LogLevel=ERROR"

cleanup() {
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
            "${SSH_USER}@localhost" "sudo systemctl poweroff" 2>/dev/null || true
        sleep 5
        kill "${QEMU_PID}" 2>/dev/null || true
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

command -v qemu-system-aarch64 >/dev/null || { echo "qemu-system-aarch64 missing"; exit 1; }
command -v sshpass >/dev/null || { echo "sshpass missing"; exit 1; }
[[ -f "${BASE_IMG}" ]] || { echo "missing ${BASE_IMG}"; exit 1; }
[[ -f "${KERNEL}" ]] || { echo "missing ${KERNEL}"; exit 1; }
[[ -f "${INITRD}" ]] || { echo "missing ${INITRD}"; exit 1; }

QEMU_PREFIX="$(brew --prefix qemu 2>/dev/null || echo /opt/homebrew)"
EFI_CODE="${QEMU_PREFIX}/share/qemu/edk2-aarch64-code.fd"
[[ -f "${EFI_CODE}" ]] || { echo "missing ${EFI_CODE}"; exit 1; }

mkdir -p "${WORK_DIR}"
EFI_VARS_TMPL="${QEMU_PREFIX}/share/qemu/edk2-aarch64-vars.fd"
[[ -f "${EFI_VARS_TMPL}" ]] && cp "${EFI_VARS_TMPL}" "${EFI_VARS}" \
    || dd if=/dev/zero of="${EFI_VARS}" bs=1m count=64 2>/dev/null

qemu-system-aarch64 \
    -M virt -cpu host -accel hvf -m 3072 -smp 2 \
    -drive "if=pflash,format=raw,readonly=on,file=${EFI_CODE}" \
    -drive "if=pflash,format=raw,file=${EFI_VARS}" \
    -kernel "${KERNEL}" \
    -initrd "${INITRD}" \
    -append "root=/dev/vda1 rw console=ttyAMA0 loglevel=3" \
    -drive "file=${BASE_IMG},format=raw,if=virtio,readonly=off,discard=unmap,cache=unsafe" \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -nographic > "${QEMU_LOG}" 2>&1 &
QEMU_PID=$!

for _ in $(seq 1 60); do
    if sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" \
        "${SSH_USER}@localhost" "exit 0" 2>/dev/null; then
        break
    fi
    sleep 2
done

sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@localhost" \
    "sudo bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
apt-get update -y
# If steam-launcher was force-installed earlier, apt may be in broken-deps state.
# Temporarily remove it so we can install the core amd64 runtime loader/libs.
dpkg -r steam-launcher:amd64 >/dev/null 2>&1 || dpkg -r steam-launcher >/dev/null 2>&1 || true
# Extract amd64 runtime files directly to avoid dpkg-divert conflicts.
mkdir -p /tmp/meridian-amd64-runtime && cd /tmp/meridian-amd64-runtime
apt-get download -qq \
  gcc-14-base:amd64 libc6:amd64 libgcc-s1:amd64 libstdc++6:amd64 zlib1g:amd64
for deb in ./*.deb; do
  dpkg-deb -x "\${deb}" /
done
ldconfig || true
cd /
# Re-install steam-launcher with force flags used by the base-image builder.
if [[ ! -f /tmp/steam-installer.deb ]]; then
  wget -q -O /tmp/steam-installer.deb https://cdn.akamai.steamstatic.com/client/installer/steam.deb
fi
dpkg --force-architecture --force-depends -i /tmp/steam-installer.deb || true
apt-mark hold steam-launcher >/dev/null 2>&1 || true
mkdir -p /lib64
if [[ -f /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 ]]; then
  ln -sf /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
fi
sync; sync; sync
'"

sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@localhost" \
    "sudo systemctl poweroff" 2>/dev/null || true
sleep 5
QEMU_PID=""

# QEMU writes may reintroduce quarantine xattrs on host-side files.
for f in "${SANDBOX}/meridian-base.img" "${SANDBOX}/expansion.img" \
          "${SANDBOX}/vmlinuz" "${SANDBOX}/initrd"; do
    [[ -f "${f}" ]] || continue
    xattr -d com.apple.quarantine "${f}" 2>/dev/null || true
    xattr -d com.apple.provenance "${f}" 2>/dev/null || true
done

echo "Patched Steam runtime deps in ${BASE_IMG}"

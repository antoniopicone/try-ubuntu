#!/usr/bin/env bash
# Boots the live ISO (see build.sh) in qemu-system-aarch64 with UEFI (edk2),
# hardware acceleration (hvf on macOS, kvm on Linux) and a virtio-gpu display
# (the desktop renders in software, llvmpipe). The live session starts in
# the host's language, taken from the shell's locale (LC_ALL, LC_MESSAGES,
# LANG; on macOS the system's when those are unset) and passed to the guest
# through QEMU's fw_cfg (live-locale.service picks it up).
# The serial console is attached to this terminal (Ctrl-A X quits QEMU,
# Ctrl-A C toggles the QEMU monitor).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./run-qemu.sh [options]

  --iso PATH     ISO to boot (default: dist/ubuntu-live-arm64.iso)
  --lang LOCALE  language of the live session (e.g. it_IT, de; default: the
                 host's). The ISO speaks English, Italian, Spanish, French,
                 German and Portuguese (Brazil); anything else is English
  --mem MiB      guest RAM (default: 4096; the live root lives in RAM)
  --cpus N       guest vCPUs (default: 4)
  --headless     no window: serial console only (login on ttyAMA0)
  --vnc DISPLAY  graphics over VNC instead of a window (e.g. :1 -> port 5901)
  --persist[=FILE]  keep changes (and snapper snapshots) across reboots on a
                 qcow2 disk. On by default (dist/persist.qcow2, 32G, created
                 on first use); it only works with the ISO build that set it up
  --no-persist   RAM only: everything is lost at shutdown
  --ssh PORT     host port forwarded to guest SSH (default: 2222)
  --efivars FILE UEFI variable store (default: dist/efivars.fd); give
                 each VM running at the same time its own
  -- ARGS...     pass the remaining arguments to QEMU unchanged
EOF
}

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
iso="$project_dir/dist/ubuntu-live-arm64.iso"
lang=""
mem=4096
cpus=4
headless=0
vnc=""
persist="$project_dir/dist/persist.qcow2"
ssh_port=2222
vars=""
while (($#)); do
  case "$1" in
    --iso)  iso=$2; shift 2 ;;
    --lang) lang=$2; shift 2 ;;
    --mem)  mem=$2; shift 2 ;;
    --cpus) cpus=$2; shift 2 ;;
    --ssh)  ssh_port=$2; shift 2 ;;
    --efivars) vars=$2; shift 2 ;;
    --headless) headless=1; shift ;;
    --vnc)  vnc=$2; shift 2 ;;
    --persist) persist="$project_dir/dist/persist.qcow2"; shift ;;
    --persist=*) persist=${1#*=}; shift ;;
    --no-persist) persist=""; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) usage >&2; exit 64 ;;
  esac
done

[[ -f "$iso" ]] || {
  echo "ISO not found: $iso (run ./build.sh first)" >&2; exit 1; }
qemu=$(command -v qemu-system-aarch64 || true)
[[ -n "$qemu" ]] || {
  echo "qemu-system-aarch64 not found (macOS: brew install qemu)" >&2; exit 1; }

# The host's language as a locale name without encoding (it_IT.UTF-8 ->
# it_IT). macOS terminals may leave LANG unset: the system's language then.
if [[ -z "$lang" ]]; then
  lang=${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}
  if [[ -z "$lang" || "$lang" == C* || "$lang" == POSIX ]] && [[ $(uname -s) == Darwin ]]; then
    lang=$(defaults read -g AppleLocale 2>/dev/null || true)   # e.g. it_IT, en_IT@rg=itzzzz
  fi
fi
lang=${lang%%[.@]*}
lang_args=()
if [[ "$lang" =~ ^[a-z]{2,3}(_[A-Z]{2})?$ ]]; then
  lang_args=(-fw_cfg name=opt/org.ubuntu.live/locale,string="$lang")
fi

# UEFI firmware: QEMU's bundled edk2 build (e.g. Homebrew's), or the
# distro's AAVMF package.
share="$(cd "$(dirname "$qemu")/.." && pwd)/share/qemu"
code=""
for f in "$share/edk2-aarch64-code.fd" /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
         /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd; do
  [[ -f "$f" ]] && { code=$f; share=$(dirname "$f"); break; }
done
[[ -n "$code" ]] || { echo "No aarch64 UEFI firmware (edk2) found" >&2; exit 1; }

# Writable EFI variable store, same size as the code image (pflash units
# must match). Kept next to the ISO so boot entries persist between runs.
[[ -n "$vars" ]] || vars="$project_dir/dist/efivars.fd"
if [[ ! -f "$vars" ]]; then
  mkdir -p "$(dirname "$vars")"
  if [[ -f "$share/edk2-arm-vars.fd" ]]; then
    cp "$share/edk2-arm-vars.fd" "$vars"
  else
    size=$(stat -c %s "$code" 2>/dev/null || stat -f %z "$code")
    dd if=/dev/zero of="$vars" bs=1 count=0 seek="$size" 2>/dev/null
  fi
fi

# edk2 takes its boot timeout from QEMU (-boot ... splash-time, in ms): 0
# skips the few seconds it would otherwise wait on the TianoCore logo before
# starting Limine. Limine has its own menu and timeout.
#
# Persistent disk: btrfslive finds it by its serial (virtio-ubuntu-persist)
# and uses it instead of RAM for everything written by the live system.
persist_args=()
if [[ -n "$persist" ]]; then
  if [[ ! -f "$persist" ]]; then
    qemu_img=$(command -v qemu-img || echo "$(dirname "$qemu")/qemu-img")
    "$qemu_img" create -q -f qcow2 "$persist" 32G
    echo "Created persistent disk $persist"
  fi
  persist_args=(
    -drive if=none,id=persist,format=qcow2,file="$persist"
    -device virtio-blk-pci,drive=persist,serial=ubuntu-persist
  )
fi

case "$(uname -s)" in
  Darwin) accel=(-accel hvf -cpu host) ;;
  Linux)  if [[ -w /dev/kvm && $(uname -m) == aarch64 ]]; then
            accel=(-accel kvm -cpu host)
          else
            accel=(-accel tcg -cpu max)
          fi ;;
  *)      accel=(-accel tcg -cpu max) ;;
esac

if ((headless)); then
  display=(-display none)
else
  display=(-device virtio-gpu-pci)
  if [[ -n "$vnc" ]]; then
    display+=(-display none -vnc "127.0.0.1$vnc")
  elif [[ $(uname -s) == Darwin ]]; then
    display+=(-display cocoa,left-command-key=on)
  fi
  display+=(-device qemu-xhci -device usb-kbd -device usb-tablet)
fi

exec "$qemu" \
  -name "Ubuntu Live" \
  -machine virt "${accel[@]}" -smp "$cpus" -m "$mem" \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$code" \
  -drive if=pflash,format=raw,unit=1,file="$vars" \
  -device virtio-scsi-pci,id=scsi0 \
  -drive if=none,id=live,media=cdrom,readonly=on,format=raw,file="$iso" \
  -device scsi-cd,bus=scsi0.0,drive=live,bootindex=0 \
  ${persist_args[@]+"${persist_args[@]}"} \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:"$ssh_port"-:22 \
  -device virtio-rng-pci \
  ${lang_args[@]+"${lang_args[@]}"} \
  -boot menu=on,splash-time=0 \
  "${display[@]}" \
  -serial mon:stdio \
  "$@"

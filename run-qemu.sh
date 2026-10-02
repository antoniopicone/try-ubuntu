#!/usr/bin/env bash
# Boots the live ISO (see build.sh) in qemu-system-aarch64 with UEFI (edk2),
# hardware acceleration (hvf on macOS, kvm on Linux) and a virtio-gpu display.
# An x86 ISO (ubuntu-live-amd64*.iso, or --arch x86) boots in
# qemu-system-x86_64 instead: accelerated on an x86 host (kvm, or hvf on an
# Intel Mac), emulated (slow) on Apple Silicon.
# On Apple Silicon it uses the QEMU from qemu/build.sh when it's there
# (dist/qemu-macos-arm64, which install.sh downloads from the release): the
# desktop then renders on the Mac's GPU (virtio-gpu-gl, VirGL -> ANGLE ->
# Metal) and, on macOS 26 with an M3 or newer, the guest gets nested
# virtualization (/dev/kvm). Any other QEMU (Homebrew's, the distro's) works
# too, with the desktop rendered in software (llvmpipe). The live session starts in
# the host's language, taken from the shell's locale (LC_ALL, LC_MESSAGES,
# LANG; on macOS the system's when those are unset) and passed to the guest
# through QEMU's fw_cfg (live-locale.service picks it up).
# The guest's serial console goes to this terminal only with --headless or
# --serial (Ctrl-A X quits QEMU, Ctrl-A C toggles the QEMU monitor); with a
# window the terminal stays quiet and the serial console is a text console
# in the window (Ctrl-Opt-2, back with Ctrl-Opt-1). Either way it's logged
# to dist/serial.log. By default the guest gets half of the
# host's CPUs and a third of its RAM (at least 4 GiB).
# When QEMU has them (the one from qemu/build.sh, Homebrew's), the guest
# also gets sound (virtio-sound, through CoreAudio on macOS), the clipboard
# shared with the window (qemu-vdagent, for the guest's spice-vdagent) and,
# with --shared-folder, a folder of the host (9p).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./run-qemu.sh [options]

  --iso PATH     ISO to boot (default: dist/ubuntu-live-arm64.iso)
  --arch ARCH    the ISO's architecture, arm or x86 (default: from the ISO's
                 name, ubuntu-live-amd64* being x86)
  --lang LOCALE  language of the live session (e.g. it_IT, de; default: the
                 host's). The ISO speaks English, Italian, Spanish, French,
                 German and Portuguese (Brazil); anything else is English
  --mem MiB      guest RAM (default: a third of the host's, at least 4096;
                 the live root lives in RAM)
  --cpus N       guest vCPUs (default: half of the host's CPUs)
  --headless     no window: serial console only (login on ttyAMA0)
  --serial       attach the serial console to this terminal instead of the
                 window's text console (Ctrl-Opt-2; always the terminal
                 with --headless)
  --vnc DISPLAY  graphics over VNC instead of a window (e.g. :1 -> port 5901;
                 no GPU acceleration)
  --no-gpu       render the desktop in software even when QEMU could use
                 the host's GPU
  --no-nested    don't expose virtualization extensions (EL2) to the guest
  --qemu PATH    qemu-system-aarch64 to use (default: the one built by
                 qemu/build.sh, if any, else the one on PATH)
  --persist[=FILE]  keep changes (and snapper snapshots) across reboots on a
                 qcow2 disk. On by default (dist/persist.qcow2, 32G, created
                 on first use); it only works with the ISO build that set it up
  --no-persist   RAM only: everything is lost at shutdown
  --ssh PORT     host port forwarded to guest SSH (default: 2222)
  --efivars FILE UEFI variable store (default: dist/efivars.fd); give
                 each VM running at the same time its own
  --shared-folder PATH
                 share a folder of the host with the guest, read/write: it
                 shows up in Files under its own name (/media/NAME)
  --no-audio     no sound device
  -- ARGS...     pass the remaining arguments to QEMU unchanged
EOF
}

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
iso="$project_dir/dist/ubuntu-live-arm64.iso"
lang=""
mem=""
cpus=""
headless=0
serial=0
vnc=""
persist="$project_dir/dist/persist.qcow2"
ssh_port=2222
vars=""
gpu=1
nested=1
qemu=""
shared=""
audio=1
arch=""
while (($#)); do
  case "$1" in
    --iso)  iso=$2; shift 2 ;;
    --arch)
      case "$2" in
        arm|arm64|aarch64) arch=arm64 ;;
        x86|x86_64|amd64) arch=amd64 ;;
        *) usage >&2; exit 64 ;;
      esac
      shift 2 ;;
    --lang) lang=$2; shift 2 ;;
    --mem)  mem=$2; shift 2 ;;
    --cpus) cpus=$2; shift 2 ;;
    --ssh)  ssh_port=$2; shift 2 ;;
    --efivars) vars=$2; shift 2 ;;
    --headless) headless=1; shift ;;
    --serial) serial=1; shift ;;
    --vnc)  vnc=$2; shift 2 ;;
    --no-gpu) gpu=0; shift ;;
    --no-nested) nested=0; shift ;;
    --qemu) qemu=$2; shift 2 ;;
    --shared-folder) shared=$2; shift 2 ;;
    --no-audio) audio=0; shift ;;
    --persist) persist="$project_dir/dist/persist.qcow2"; shift ;;
    --persist=*) persist=${1#*=}; shift ;;
    --no-persist) persist=""; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) usage >&2; exit 64 ;;
  esac
done

[[ -f "$iso" ]] || {
  echo "ISO not found: $iso (run ./build.sh first, or install.sh to download it)" >&2; exit 1; }
if [[ -z "$arch" ]]; then
  case "$(basename "$iso")" in *amd64*|*x86*) arch=amd64 ;; *) arch=arm64 ;; esac
fi
# x86's state apart from arm64's: a persistent disk only works with its
# own ISO, and the UEFI variable stores differ.
if [[ $arch == amd64 ]]; then
  [[ "$persist" == "$project_dir/dist/persist.qcow2" ]] && persist="$project_dir/dist/persist-amd64.qcow2"
  [[ -n "$vars" ]] || vars="$project_dir/dist/efivars-amd64.fd"
fi
# The QEMU built by qemu/build.sh (install.sh puts it in the same place),
# else the system's.
qemu_name=qemu-system-aarch64
[[ $arch == amd64 ]] && qemu_name=qemu-system-x86_64
bundled="$project_dir/dist/qemu-macos-arm64/bin/qemu-system-aarch64"
if [[ -z "$qemu" && $arch == arm64 && -x "$bundled" && $(uname -s) == Darwin && $(uname -m) == arm64 ]]; then
  qemu=$bundled
fi
[[ -n "$qemu" ]] || qemu=$(command -v "$qemu_name" || true)
[[ -n "$qemu" && -x "$qemu" ]] || {
  echo "$qemu_name not found (macOS: brew install qemu$([[ $arch == arm64 ]] && echo ", or ./qemu/build.sh"))" >&2; exit 1; }

# Defaults from the host: half of its CPUs, a third of its RAM (min 4 GiB).
if [[ -z "$cpus" ]]; then
  host_cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
  cpus=$((host_cpus / 2))
  ((cpus >= 1)) || cpus=1
fi
if [[ -z "$mem" ]]; then
  if [[ $(uname -s) == Darwin ]]; then
    host_mib=$(( $(sysctl -n hw.memsize) / 1048576 ))
  else
    host_mib=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))
  fi
  mem=$((host_mib / 3))
  ((mem >= 4096)) || mem=4096
fi

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
# distro's package (AAVMF on Debian/Ubuntu, edk2-aarch64 on Arch and Fedora).
share="$(cd "$(dirname "$qemu")/.." && pwd)/share/qemu"
code=""
if [[ $arch == amd64 ]]; then
  # OVMF: QEMU's (Homebrew's edk2-x86_64-code.fd), or the distro's
  firmware_list=("$share/edk2-x86_64-code.fd" /opt/homebrew/share/qemu/edk2-x86_64-code.fd
                 /usr/local/share/qemu/edk2-x86_64-code.fd
                 /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd
                 /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/ovmf/OVMF_CODE.fd)
  vars_templates=(edk2-i386-vars.fd OVMF_VARS_4M.fd OVMF_VARS.4m.fd OVMF_VARS.fd)
else
  firmware_list=("$share/edk2-aarch64-code.fd" /opt/homebrew/share/qemu/edk2-aarch64-code.fd
                 /usr/local/share/qemu/edk2-aarch64-code.fd
                 /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
                 /usr/share/edk2/aarch64/QEMU_CODE.fd /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw)
  vars_templates=(edk2-arm-vars.fd)
fi
for f in "${firmware_list[@]}"; do
  [[ -f "$f" ]] && { code=$f; share=$(dirname "$f"); break; }
done
[[ -n "$code" ]] || { echo "No $arch UEFI firmware (edk2/OVMF) found" >&2; exit 1; }

# Writable EFI variable store, same size as the code image (pflash units
# must match). Kept next to the ISO so boot entries persist between runs.
[[ -n "$vars" ]] || vars="$project_dir/dist/efivars.fd"
if [[ ! -f "$vars" ]]; then
  mkdir -p "$(dirname "$vars")"
  template=""
  for t in "${vars_templates[@]}"; do
    [[ -f "$share/$t" ]] && { template="$share/$t"; break; }
  done
  if [[ -n "$template" ]]; then
    cp "$template" "$vars"
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
# It extends the seed of the ISO that created it, so with any other ISO
# btrfslive leaves it alone and the session silently runs in RAM. The ISO's
# checksum (its .sha256, else size and mtime) is kept next to the disk
# (FILE.iso): when the ISO changes, the old disk is set aside, not deleted,
# and a new one is created.
persist_args=()
if [[ -n "$persist" ]]; then
  iso_id=$(cut -d' ' -f1 "$iso.sha256" 2>/dev/null || true)
  [[ -n "$iso_id" ]] || iso_id=$(stat -f '%z-%m' "$iso" 2>/dev/null || stat -c '%s-%Y' "$iso")
  if [[ -f "$persist" ]]; then
    disk_id=$(cat "$persist.iso" 2>/dev/null || true)
    # No record (a disk from before this check): btrfs writes to the disk at
    # every boot it's used, so one older than the ISO was never used with it.
    if [[ -z "$disk_id" && "$persist" -ot "$iso" ]]; then
      disk_id=unknown
    fi
    if [[ -n "$disk_id" && "$disk_id" != "$iso_id" ]]; then
      old="${persist%.qcow2}-$(date -r "$persist" +%Y%m%d-%H%M%S).qcow2"
      mv "$persist" "$old"
      [[ -f "$persist.iso" ]] && mv "$persist.iso" "$old.iso"
      echo "The persistent disk was made by another ISO and can't be used with this one:"
      echo "  moved to $old (it still works with that ISO: --persist=$old)"
    fi
  fi
  if [[ ! -f "$persist" ]]; then
    qemu_img=$(command -v qemu-img || echo "$(dirname "$qemu")/qemu-img")
    "$qemu_img" create -q -f qcow2 "$persist" 32G
    echo "Created persistent disk $persist"
  fi
  echo "$iso_id" > "$persist.iso"
  persist_args=(
    -drive if=none,id=persist,format=qcow2,file="$persist"
    -device virtio-blk-pci,drive=persist,serial=ubuntu-persist
  )
fi

machine=virt
if [[ $arch == amd64 ]]; then
  machine=q35
  if [[ $(uname -s) == Linux && $(uname -m) == x86_64 && -w /dev/kvm ]]; then
    accel=(-accel kvm -cpu host)
  elif [[ $(uname -s) == Darwin && $(uname -m) == x86_64 ]]; then
    accel=(-accel hvf -cpu host)
  else
    accel=(-accel tcg,thread=multi -cpu max)
    echo "Emulating x86 (no acceleration on this $(uname -m) host): it's slow." >&2
  fi
else
case "$(uname -s)" in
  Darwin) if [[ $(uname -m) == arm64 ]]; then
            # HVF has no usable guest PMU: don't advertise one.
            accel=(-accel hvf -cpu host,pmu=off)
            # Nested virtualization: EL2 in the guest, with Hypervisor.framework's
            # GICv3. It needs macOS 26 and an M3 or newer; rather than guess
            # from the model, ask QEMU to create (and quit) such a machine.
            # macOS 15 can pass this probe and then fail at boot, hence the
            # version check.
            if ((nested)) && (( $(sw_vers -productVersion | cut -d. -f1) >= 26 )) &&
               printf '%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"quit"}' |
                 "$qemu" -machine virt,gic-version=3,virtualization=on \
                   -accel hvf,kernel-irqchip=on -cpu host,pmu=off -smp 1 -m 128M \
                   -nodefaults -display none -S -qmp stdio >/dev/null 2>&1; then
              machine=virt,gic-version=3,virtualization=on
              accel=(-accel hvf,kernel-irqchip=on -cpu host,pmu=off)
            fi
          else
            accel=(-accel tcg -cpu max)   # Intel Mac: arm64 is emulated
          fi ;;
  Linux)  if [[ -w /dev/kvm && $(uname -m) == aarch64 ]]; then
            accel=(-accel kvm -cpu host)
          else
            accel=(-accel tcg -cpu max)
          fi ;;
  *)      accel=(-accel tcg -cpu max) ;;
esac
fi

# At EL2 under HVF, edk2's timer interrupt (the EL2 physical timer) never
# fires: anything in the firmware that waits, Limine's menu included, hangs.
# Linux doesn't use that timer, so with nested virtualization QEMU loads the
# kernel itself (edk2 still starts it, without waiting on anything): the
# ISO's kernel, initramfs and the command line of Limine's default entry.
# No Limine menu, then: --no-nested for it (e.g. to boot a snapshot).
kernel_args=()
if [[ "$machine" == *virtualization=on* ]]; then
  stamp=$(stat -f '%z-%m' "$iso")
  kdir="$project_dir/dist/.kernel-$(basename "$iso" .iso)"
  if [[ "$(cat "$kdir/stamp" 2>/dev/null)" != "$stamp" ]]; then
    rm -rf "$kdir"; mkdir -p "$kdir"
    tar -xf "$iso" -C "$kdir" live/Image live/initrd boot/limine/limine.conf
    echo "$stamp" > "$kdir/stamp"
  fi
  # limine.conf: ${NAME}=value macros, then the first entry's cmdline.
  cmdline=$(awk '
    /^\$\{[A-Z_]+\}=/ { i = index($0, "="); macro[substr($0, 1, i - 1)] = substr($0, i + 1); next }
    /^[ \t]*cmdline:/ { sub(/^[ \t]*cmdline:[ \t]*/, "")
                        for (m in macro) while ((i = index($0, m)) > 0)
                          $0 = substr($0, 1, i - 1) macro[m] substr($0, i + length(m))
                        print; exit }' "$kdir/boot/limine/limine.conf")
  [[ -n "$cmdline" ]] || { echo "No kernel command line in the ISO's limine.conf" >&2; exit 1; }
  kernel_args=(-kernel "$kdir/live/Image" -initrd "$kdir/live/initrd" -append "$cmdline")
fi

# Serial console on the terminal only when asked (always with --headless):
# otherwise the guest's boot and console output would flood it. Without it,
# it's a text console in the window (View menu, or Ctrl-Opt-2 and back with
# Ctrl-Opt-1; the same keys over VNC): a login prompt and the kernel's
# messages even when the desktop doesn't come up. Either way it's also
# logged to dist/serial.log (overwritten at every boot).
serial_log="$(dirname "$vars")/serial.log"
if ((headless || serial)); then
  serial_args=(-chardev "stdio,id=serial0,mux=on,signal=off,logfile=$serial_log"
               -serial chardev:serial0 -mon chardev=serial0,mode=readline)
else
  serial_args=(-chardev "vc,id=serial0,logfile=$serial_log" -serial chardev:serial0)
fi

# What this QEMU can do: devices, audio backends, chardev backends.
qemu_devices=$("$qemu" -device help 2>/dev/null || true)
qemu_audio=$("$qemu" -audiodev help 2>/dev/null || true)
qemu_chardevs=$("$qemu" -machine none -chardev help 2>/dev/null || true)
has_device() { grep -qF "name \"$1\"" <<<"$qemu_devices"; }

# GPU acceleration (VirGL) needs a QEMU with virtio-gpu-gl-pci and an
# OpenGL display: on macOS that's the one from qemu/build.sh, whose Cocoa
# window renders through ANGLE (OpenGL ES) on Metal. It follows the window's
# size and the display's refresh rate.
if ((gpu)) && [[ $arch == arm64 && -z "$vnc" && $(uname -s) == Darwin ]] && has_device virtio-gpu-gl-pci; then
  gpu=1
else
  gpu=0
fi

if ((headless)); then
  display=(-display none)
elif ((gpu)); then
  display=(-device virtio-gpu-gl-pci -display cocoa,gl=es,zoom-to-fit=on,left-command-key=on)
else
  display=(-device virtio-gpu-pci)
  [[ $arch == amd64 ]] && display=(-device virtio-vga)
  if [[ -n "$vnc" ]]; then
    display+=(-display none -vnc "127.0.0.1$vnc")
  elif [[ $(uname -s) == Darwin ]]; then
    display+=(-display cocoa,left-command-key=on)
  fi
fi
# The virt machine has no input devices of its own: add them to every
# graphical display, GPU-accelerated or not.
((headless)) || display+=(-device qemu-xhci -device usb-kbd -device usb-tablet)

# Free-page reporting gives the RAM the guest frees back to macOS: with
# HVF that needs the patch in qemu/build.sh's QEMU (without it, QEMU can't
# remap the pages), so only there.
balloon_args=()
if [[ "${accel[1]}" == hvf* ]] && LC_ALL=C grep -aqF 'HVF free-page backing replacement failed' "$qemu"; then
  balloon_args=(-device virtio-balloon-pci,free-page-reporting=on)
elif [[ "${accel[1]}" == kvm ]]; then
  balloon_args=(-device virtio-balloon-pci,free-page-reporting=on)
fi

# Sound: virtio-sound, played by the host's sound system (the guest's
# PipeWire sees it as an ordinary sound card).
audio_args=()
if ((audio)); then
  case "$(uname -s)" in
    Darwin) backends="coreaudio" ;;
    *)      backends="pipewire pa alsa" ;;
  esac
  backend=""
  for b in $backends; do
    grep -qx "$b" <<<"$qemu_audio" && { backend=$b; break; }
  done
  if [[ -n "$backend" ]] && has_device virtio-sound-pci; then
    # QEMU's CoreAudio only plays: just the output stream, no microphone
    streams=2
    [[ "$backend" == coreaudio ]] && streams=1
    audio_args=(-audiodev "$backend,id=snd0" -device "virtio-sound-pci,audiodev=snd0,streams=$streams")
  else
    echo "No sound: this QEMU has no virtio-sound or no ${backends// / / } backend." >&2
  fi
fi

# Clipboard shared with the window: QEMU's own SPICE agent channel, which
# the guest's spice-vdagent talks to (as with a SPICE client).
clipboard_args=()
if ((!headless)); then
  if grep -qx '  *qemu-vdagent' <<<"$qemu_chardevs" && has_device virtserialport; then
    clipboard_args=(-device virtio-serial-pci
                    -chardev qemu-vdagent,id=vdagent,name=vdagent,clipboard=on
                    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0)
  else
    echo "No shared clipboard: this QEMU has no qemu-vdagent." >&2
  fi
fi

# Shared folder: 9p, read/write with the permissions of whoever runs QEMU
# (security_model=none: the guest's owners aren't stored). The guest
# (live-shared-folder.service) mounts the "shared" tag in /media, under the
# name passed through fw_cfg.
shared_args=()
if [[ -n "$shared" ]]; then
  [[ -d "$shared" ]] || { echo "Not a folder: $shared" >&2; exit 1; }
  has_device virtio-9p-pci || {
    echo "This QEMU can't share folders (no virtio-9p): use the one from qemu/build.sh or Homebrew's." >&2
    exit 1; }
  shared=$(cd "$shared" && pwd -P)
  shared_name=$(basename "$shared")
  # Commas are QEMU's option separators: doubled, they're literal.
  shared_args=(-virtfs "local,path=${shared//,/,,},mount_tag=shared,security_model=none,id=shared"
               -fw_cfg "name=opt/org.ubuntu.live/shared-name,string=${shared_name//,/,,}")
fi

# With nested virtualization a reboot started by the guest crashes edk2
# (a stack overflow in ArmCpuDxe: once Linux has used EL2, HVF doesn't
# reset all of it, while a reset from QEMU is fine). So there a guest
# reboot makes QEMU quit, and it's started again from scratch: the serial
# log tells a reboot ("reboot: Restarting system") from a power-off.
reboot_args=()
[[ "$machine" == *virtualization=on* ]] && reboot_args=(-action reboot=shutdown)

qemu_args=(
  -name "Ubuntu Live"
  -machine "$machine" "${accel[@]}" -smp "$cpus" -m "$mem"
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$code"
  -drive if=pflash,format=raw,unit=1,file="$vars"
  -device virtio-scsi-pci,id=scsi0
  -drive if=none,id=live,media=cdrom,readonly=on,format=raw,file="$iso"
  -device scsi-cd,bus=scsi0.0,drive=live,bootindex=0
  ${persist_args[@]+"${persist_args[@]}"}
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:"$ssh_port"-:22
  -device virtio-rng-pci
  ${balloon_args[@]+"${balloon_args[@]}"}
  ${audio_args[@]+"${audio_args[@]}"}
  ${clipboard_args[@]+"${clipboard_args[@]}"}
  ${shared_args[@]+"${shared_args[@]}"}
  ${kernel_args[@]+"${kernel_args[@]}"}
  ${lang_args[@]+"${lang_args[@]}"}
  -boot menu=on,splash-time=0
  "${display[@]}"
  "${serial_args[@]}"
  ${reboot_args[@]+"${reboot_args[@]}"}
)
if ((${#reboot_args[@]} == 0)); then
  exec "$qemu" "${qemu_args[@]}" "$@"
fi
while :; do
  status=0
  "$qemu" "${qemu_args[@]}" "$@" || status=$?
  ((status == 0)) && tail -n 3 "$serial_log" 2>/dev/null | grep -qa 'reboot: Restarting system' ||
    exit "$status"
  echo "The guest rebooted: restarting QEMU"
done

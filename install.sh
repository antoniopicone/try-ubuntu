#!/bin/sh
# Downloads the live ISO from the latest GitHub release, gets QEMU and boots
# the ISO with run-qemu.sh. Or, with --on-usb, builds the ISO for real
# computers and writes it to a USB stick. Meant to be piped into sh:
#
#   curl -fsSL https://raw.githubusercontent.com/antoniopicone/try-ubuntu/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --lang de_DE --no-persist
#   curl -fsSL .../install.sh | sh -s -- --rebuild
#   curl -fsSL .../install.sh | sh -s -- --arch x86 --on-usb
#
# --arch arm|x86: the ISO's architecture (default: arm, i.e. arm64). An x86
# ISO runs emulated (slow) on Apple Silicon, accelerated on an x86 host.
#
# Without --on-usb, arguments go to run-qemu.sh unchanged, except --rebuild:
# it deletes what this script downloaded and the caches (the ISO, the QEMU
# build, run-qemu.sh, the kernel run-qemu.sh extracts from the ISO) and
# downloads the latest release's again. The persistent disk and the UEFI
# variables stay. The ISO, the persistent disk and run-qemu.sh live in
# $TRY_UBUNTU_DIR (default: ~/.local/share/try-ubuntu).
# Running it again boots the same ISO, or downloads the new one when there
# is a newer release (the old persistent disk is set aside: it only works
# with the ISO that set it up).
#
# --on-usb: a live USB stick to boot a real computer, from which the welcome
# app can install Ubuntu on a disk (with at least 20 GB, whole or its free
# space). The releases' ISOs are made for QEMU (the "virtual" kernel, no
# firmware): this builds the real-computer flavour locally instead
# (build.sh --hardware: the generic kernel, all of linux-firmware), from the
# release's sources (or the checkout this script is in), with podman (many
# hours for x86 on Apple Silicon, emulated). Then it lists the USB disks, asks which one to erase, asks
# again, and writes the ISO to it. Other arguments go to build.sh (--xkb it).
# The computer must boot it with Secure Boot off (Limine isn't signed).
#
# QEMU: on Apple Silicon, the release's build for arm64 ISOs (qemu/build.sh:
# GPU acceleration and nested virtualization), in $TRY_UBUNTU_DIR/dist;
# otherwise Homebrew's on a Mac, the distribution's on Linux.
set -eu

REPO=${TRY_UBUNTU_REPO:-antoniopicone/try-ubuntu}
DIR=${TRY_UBUNTU_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/try-ubuntu}
# This script's own checkout, when it's run from one (not piped)
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P || true)

say()  { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

sudo_run() {
  if [ "$(id -u)" -eq 0 ]; then "$@"
  elif has sudo; then sudo "$@"
  else die "run as root or install sudo: $*"; fi
}

sha256() {
  if has sha256sum; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# The answer to a question, from the terminal even under curl | sh.
ask() {
  printf '%s ' "$1" >&2
  read -r answer </dev/tty || die "no terminal to answer from"
  printf '%s\n' "$answer"
}

# UEFI firmware locations known to run-qemu.sh (Linux distributions).
linux_firmware_found() {
  if [ "$arch" = amd64 ]; then
    set -- /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
           /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/ovmf/OVMF_CODE.fd \
           /usr/share/qemu/edk2-x86_64-code.fd
  else
    set -- /usr/share/qemu/edk2-aarch64-code.fd /usr/share/AAVMF/AAVMF_CODE.fd \
           /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/edk2/aarch64/QEMU_CODE.fd \
           /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw
  fi
  for f do
    [ -f "$f" ] && return 0
  done
  return 1
}

# The release's QEMU for Apple Silicon (see qemu/build.sh), unless this
# release's is already there. Returns 1 when the release has none.
install_qemu_release() {
  qemu_tgz=qemu-macos-arm64.tar.gz
  printf '%s\n' "$sums" | grep -q " \*\{0,1\}$qemu_tgz\$" || return 1
  qemu_stamp="$dist/qemu-macos-arm64.release"
  if [ -x "$dist/qemu-macos-arm64/bin/qemu-system-aarch64" ] &&
     [ "$(cat "$qemu_stamp" 2>/dev/null || true)" = "$tag" ]; then
    return 0
  fi
  say "Downloading QEMU for Apple Silicon ($tag)"
  tmp=$(mktemp -d "$dist/.qemu.XXXXXX")
  curl -fL --progress-bar -o "$tmp/$qemu_tgz" "$base/$qemu_tgz" </dev/null || {
    rm -rf "$tmp"; die "QEMU download failed; run this again"; }
  if [ "$(sha256 "$tmp/$qemu_tgz")" != "$(printf '%s\n' "$sums" | grep " \*\{0,1\}$qemu_tgz\$" | cut -d' ' -f1)" ]; then
    rm -rf "$tmp"; die "checksum mismatch for $qemu_tgz; run this again"
  fi
  tar -xzf "$tmp/$qemu_tgz" -C "$tmp"
  rm -rf "$dist/qemu-macos-arm64"
  mv "$tmp/qemu-macos-arm64" "$dist/qemu-macos-arm64"
  rm -rf "$tmp"
  printf '%s\n' "$tag" > "$qemu_stamp"
}

# --rebuild: everything downloaded from the releases, and the caches. Not
# the persistent disks (persist*.qcow2) nor the UEFI variables (efivars*.fd).
purge_downloads() {
  say "Deleting the downloaded ISO, QEMU and caches in $dist"
  rm -rf "$dist"/*.iso "$dist"/*.iso.*.part "$dist"/*.release \
    "$dist/qemu-macos-arm64" "$dist"/.qemu.* "$dist"/.kernel-* "$dist"/.app-* \
    "$DIR/run-qemu.sh" "$DIR/try-ubuntu.icns"
}

install_qemu() {
  qemu=qemu-system-aarch64
  [ "$arch" = amd64 ] && qemu=qemu-system-x86_64
  case "$os" in
    Darwin)
      [ "$arch" = arm64 ] && [ "$host" = arm64 ] && install_qemu_release && return 0
      has "$qemu" && return 0
      has brew || die "QEMU is missing and Homebrew isn't installed: see https://brew.sh, then run this again"
      say "Installing QEMU (brew install qemu)"
      brew install qemu ;;
    Linux)
      has "$qemu" && linux_firmware_found && return 0
      say "Installing QEMU and the $arch UEFI firmware"
      if has apt-get; then
        sudo_run apt-get update -qq
        if [ "$arch" = amd64 ]; then
          sudo_run apt-get install -y qemu-system-x86 ovmf qemu-utils qemu-system-gui
        else
          sudo_run apt-get install -y qemu-system-arm qemu-efi-aarch64 qemu-utils qemu-system-gui
        fi
      elif has dnf; then
        if [ "$arch" = amd64 ]; then
          sudo_run dnf install -y qemu-system-x86 edk2-ovmf qemu-img qemu-ui-gtk
        else
          sudo_run dnf install -y qemu-system-aarch64 edk2-aarch64 qemu-img qemu-ui-gtk
        fi
      elif has pacman; then
        if [ "$arch" = amd64 ]; then
          sudo_run pacman -S --needed --noconfirm qemu-system-x86 edk2-ovmf qemu-img qemu-ui-gtk
        else
          sudo_run pacman -S --needed --noconfirm qemu-system-aarch64 edk2-aarch64 qemu-img qemu-ui-gtk
        fi
      else
        die "install $qemu and its UEFI firmware (edk2/OVMF/AAVMF) with your package manager, then run this again"
      fi ;;
  esac
  has "$qemu" || die "$qemu still not found after installing QEMU"
}

# --- --on-usb ------------------------------------------------------------------

# The sources to build from: this script's checkout, or the release's.
get_sources() {
  if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/build.sh" ] && [ -f "$SELF_DIR/scripts/build-rootfs.sh" ]; then
    src=$SELF_DIR
    say "Building from the checkout in $src"
    return
  fi
  src="$DIR/src/$tag"
  if [ ! -f "$src/build.sh" ]; then
    say "Downloading the sources of $tag"
    rm -rf "$src"
    mkdir -p "$src"
    curl -fsSL "https://github.com/$REPO/archive/refs/tags/$tag.tar.gz" </dev/null |
      tar -xzf - -C "$src" --strip-components=1 || { rm -rf "$src"; die "can't download the sources of $tag"; }
  fi
}

# podman, with a machine able to build (on a Mac: rootful, for loop
# devices; room and memory for compiling GNOME).
get_podman() {
  case "$os" in
    Darwin)
      if ! has podman; then
        has brew || die "podman is needed and Homebrew isn't installed: see https://brew.sh"
        say "Installing podman (brew install podman)"
        brew install podman
      fi
      if ! podman machine inspect >/dev/null 2>&1; then
        cpus=$(sysctl -n hw.ncpu); cpus=$((cpus > 2 ? cpus - 2 : 1))
        say "Creating the podman machine ($cpus CPUs, 8 GiB of RAM, 200 GB of disk)"
        podman machine init --rootful --cpus "$cpus" --memory 8192 --disk-size 200
      fi
      podman machine inspect --format '{{.State}}' 2>/dev/null | grep -qx running ||
        podman machine start ;;
    Linux)
      has podman && return
      say "Installing podman"
      if has apt-get; then sudo_run apt-get update -qq && sudo_run apt-get install -y podman
      elif has dnf; then sudo_run dnf install -y podman
      elif has pacman; then sudo_run pacman -S --needed --noconfirm podman
      else die "install podman with your package manager, then run this again"; fi ;;
  esac
}

# The USB disks: "device|bytes|description" lines.
list_usb() {
  case "$os" in
    Darwin)
      for d in $(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+/ { print $1 }'); do
        info=$(diskutil info "$d")
        bytes=$(printf '%s\n' "$info" | sed -n 's/^ *Disk Size:.*(\([0-9]*\) Bytes).*/\1/p')
        name=$(printf '%s\n' "$info" | sed -n 's/^ *Device \/ Media Name: *//p')
        proto=$(printf '%s\n' "$info" | sed -n 's/^ *Protocol: *//p')
        printf '%s|%s|%s (%s)\n' "$d" "${bytes:-0}" "${name:-disk}" "${proto:-external}"
      done ;;
    Linux)
      lsblk -dnpb -o NAME,TRAN,SIZE,TYPE | while read -r name tran size type; do
        [ "$tran" = usb ] && [ "$type" = disk ] || continue
        model=$(lsblk -dno VENDOR,MODEL "$name" | sed 's/  */ /g; s/ *$//')
        printf '%s|%s|%s\n' "$name" "$size" "${model:-USB disk}"
      done ;;
  esac
}

human() { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1000000000 }'; }

write_usb() {
  iso_size=$(wc -c < "$1" | tr -d ' ')
  disks=$(list_usb)
  [ -n "$disks" ] || die "no USB disk found: plug one in (at least $(human "$iso_size")) and run this again"
  printf '\nUSB disks:\n' >&2
  i=0
  printf '%s\n' "$disks" | while IFS='|' read -r dev bytes desc; do
    i=$((i + 1))
    printf '  %d) %s  %s  %s\n' "$i" "$dev" "$(human "$bytes")" "$desc" >&2
  done
  choice=$(ask "Which one gets the live system (number, or Enter to stop)?")
  [ -n "$choice" ] || die "stopped: nothing was written"
  case "$choice" in *[!0-9]*) die "not a number: $choice" ;; esac
  line=$(printf '%s\n' "$disks" | sed -n "${choice}p")
  [ -n "$line" ] || die "no disk number $choice"
  dev=${line%%|*}; rest=${line#*|}; bytes=${rest%%|*}; desc=${rest#*|}
  [ "$bytes" -ge "$iso_size" ] || die "$dev is too small ($(human "$bytes")) for the ISO ($(human "$iso_size"))"
  warn "everything on $dev ($desc, $(human "$bytes")) will be erased"
  confirm=$(ask "Type $dev to erase it and write the live system:")
  [ "$confirm" = "$dev" ] || die "stopped: nothing was written"

  say "Writing $(basename "$1") to $dev (it takes a few minutes)"
  case "$os" in
    Darwin)
      diskutil unmountDisk force "$dev" >/dev/null
      raw="/dev/r${dev#/dev/}"
      progress=""
      dd if=/dev/zero of=/dev/null count=1 status=progress 2>/dev/null && progress=status=progress
      sudo_run dd if="$1" of="$raw" bs=4m $progress
      sync
      diskutil eject "$dev" >/dev/null || true ;;
    Linux)
      for p in $(lsblk -lnpo NAME "$dev" | tail -n +2); do
        sudo_run umount "$p" 2>/dev/null || true
      done
      sudo_run dd if="$1" of="$dev" bs=4M conv=fsync oflag=direct status=progress
      sync ;;
  esac
  say "Done: the USB stick is ready"
  cat >&2 <<EOF

  Boot the computer from it: its boot menu (often F12, F11, F9 or Esc at
  power-on), with Secure Boot turned off in the firmware settings (the
  bootloader, Limine, isn't signed). In the live session the welcome app
  can install Ubuntu on a disk with at least 20 GB: the whole disk, or its
  free space next to what is there.
EOF
}

on_usb() {
  get_sources
  get_podman
  iso="$src/dist/ubuntu-live-$arch-hardware.iso"
  stamp="$iso.release"
  # From the release's sources, a new release means a new build; from a
  # checkout, only --rebuild or a missing ISO does
  outdated=0
  [ "$src" != "$SELF_DIR" ] && [ "$(cat "$stamp" 2>/dev/null || true)" != "$tag" ] && outdated=1
  if [ "$rebuild" = 1 ] || [ ! -f "$iso" ] || [ "$outdated" = 1 ]; then
    say "Building the live ISO for real computers ($arch, $tag)"
    if [ "$arch" != "$host" ]; then
      warn "building $arch on $host is emulated: the first build takes many hours"
    else
      warn "the first build takes a while (later ones minutes)"
    fi
    if [ "$os" = Linux ]; then
      # Rootful podman: the ISO step needs loop devices
      sudo_run bash "$src/build.sh" --arch "$arch_opt" --hardware "$@" </dev/null
    else
      bash "$src/build.sh" --arch "$arch_opt" --hardware "$@" </dev/null
    fi
    printf '%s\n' "$tag" > "$stamp"
  else
    say "Using $iso, already built for $tag"
  fi
  write_usb "$iso"
}

main() {
  # --rebuild, --arch and --on-usb are ours; everything else goes to
  # run-qemu.sh (or with --on-usb to build.sh; after --, to QEMU, untouched).
  rebuild=0 passthrough=0 on_usb=0 arch_opt=arm expect_arch=0
  for arg do
    shift
    if [ "$expect_arch" = 1 ]; then
      arch_opt=$arg expect_arch=0
      continue
    fi
    case "$passthrough:$arg" in
      0:--rebuild) rebuild=1 ;;
      0:--on-usb) on_usb=1 ;;
      0:--arch) expect_arch=1 ;;
      0:--arch=*) arch_opt=${arg#--arch=} ;;
      0:--) passthrough=1; set -- "$@" "$arg" ;;
      *) set -- "$@" "$arg" ;;
    esac
  done
  case "$arch_opt" in
    arm|arm64|aarch64) arch=arm64 arch_opt=arm ;;
    x86|x86_64|amd64) arch=amd64 arch_opt=x86 ;;
    *) die "--arch is arm or x86, not '$arch_opt'" ;;
  esac

  os=$(uname -s)
  case "$os" in
    Darwin|Linux) ;;
    *) die "unsupported OS: $os (macOS and Linux only; on Windows use WSL)" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) host=arm64 ;;
    x86_64|amd64)  host=amd64 ;;
    *) die "unsupported CPU: $(uname -m)" ;;
  esac
  has curl || die "curl is required"
  has bash || die "bash is required (run-qemu.sh and build.sh are bash scripts)"

  # /releases/latest redirects to /releases/tag/<tag>: no API call, no rate limit.
  tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") ||
    die "can't reach github.com/$REPO"
  tag=${tag##*/}
  case "$tag" in ''|latest|releases) die "$REPO has no release yet" ;; esac
  base="https://github.com/$REPO/releases/download/$tag"

  if [ "$on_usb" = 1 ]; then
    on_usb "$@"
    return
  fi

  dist="$DIR/dist"
  mkdir -p "$dist"
  sums=$(curl -fsSL "$base/SHA256SUMS") || die "no SHA256SUMS in release $tag"

  iso="ubuntu-live-$arch.iso"
  printf '%s\n' "$sums" | grep -q " \*\{0,1\}$iso\$" ||
    die "release $tag has no $arch ISO (build one with ./build.sh --arch $arch_opt, then ./run-qemu.sh --iso dist/$iso)"
  if [ "$arch" != "$host" ]; then
    warn "an $arch ISO on an $host computer: QEMU emulates it without hardware acceleration, so it will be slow"
  fi
  expected=$(printf '%s\n' "$sums" | grep " \*\{0,1\}$iso\$" | cut -d' ' -f1)

  # The release of the ISO in place, if any: its persistent disk only works
  # with it (see below). run-qemu.sh keeps x86's apart.
  persist=persist.qcow2
  [ "$arch" = amd64 ] && persist=persist-amd64.qcow2
  stamp="$dist/$iso.release"
  current=$(cat "$stamp" 2>/dev/null || true)
  [ "$rebuild" = 0 ] || purge_downloads

  install_qemu
  if [ "$os" = Linux ] && [ "$arch" = "$host" ] && [ -e /dev/kvm ] && [ ! -w /dev/kvm ]; then
    warn "/dev/kvm isn't writable: add yourself to the kvm group (sudo usermod -aG kvm \$USER, then log in again) for hardware acceleration"
  fi

  # The ISO, unless this release's is already there.
  if [ ! -f "$dist/$iso" ] || [ "$current" != "$tag" ]; then
    part="$dist/$iso.$tag.part"
    for f in "$dist/$iso".*.part; do
      [ "$f" = "$part" ] || rm -f "$f"
    done
    say "Downloading $iso ($tag)"
    curl -fL --progress-bar -C - -o "$part" "$base/$iso" </dev/null ||
      die "download failed; run this again to resume it"
    say "Checking the SHA-256"
    if [ "$(sha256 "$part")" != "$expected" ]; then
      rm -f "$part"
      die "checksum mismatch for $iso; run this again"
    fi
    mv -f "$part" "$dist/$iso"
    printf '%s\n' "$tag" > "$stamp"
    if [ -n "$current" ] && [ "$current" != "$tag" ] && [ -f "$dist/$persist" ]; then
      old="${persist%.qcow2}-$current.qcow2"
      mv "$dist/$persist" "$dist/$old"
      if [ -f "$dist/$persist.iso" ]; then
        mv "$dist/$persist.iso" "$dist/$old.iso"
      fi
      say "The persistent disk of $current only works with its ISO: moved to $dist/$old"
    fi
  fi

  # run-qemu.sh from the same tag as the ISO.
  curl -fsSL -o "$DIR/run-qemu.sh" "https://raw.githubusercontent.com/$REPO/$tag/run-qemu.sh" ||
    die "can't download run-qemu.sh"
  chmod +x "$DIR/run-qemu.sh"
  # The Dock icon of QEMU's window on a Mac (run-qemu.sh does without it too)
  [ "$(uname -s)" != Darwin ] ||
    curl -fsSL -o "$DIR/try-ubuntu.icns" \
      "https://raw.githubusercontent.com/$REPO/$tag/assets/try-ubuntu.icns" 2>/dev/null ||
    rm -f "$DIR/try-ubuntu.icns"

  say "Booting Ubuntu Live $tag (close the window to quit)"
  # Under curl | sh stdin is the script: QEMU's serial console (--headless,
  # --serial) needs the terminal.
  if { : </dev/tty; } 2>/dev/null; then
    exec bash "$DIR/run-qemu.sh" --iso "$dist/$iso" --arch "$arch_opt" "$@" </dev/tty
  fi
  exec bash "$DIR/run-qemu.sh" --iso "$dist/$iso" --arch "$arch_opt" "$@"
}

# In a function, so sh has read the whole script before anything runs.
main "$@"

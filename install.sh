#!/bin/sh
# Downloads the live ISO from the latest GitHub release, installs QEMU if
# it's missing and boots the ISO with run-qemu.sh. Meant to be piped into sh:
#
#   curl -fsSL https://raw.githubusercontent.com/antoniopicone/try-ubuntu/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --lang de_DE --no-persist
#
# Arguments go to run-qemu.sh unchanged. The ISO, the persistent disk and
# run-qemu.sh live in $TRY_UBUNTU_DIR (default: ~/.local/share/try-ubuntu).
# Running it again boots the same ISO, or downloads the new one when there
# is a newer release (the old persistent disk is set aside: it only works
# with the ISO that set it up).
#
# The ISO matching the host's CPU is used when the release has one;
# otherwise the arm64 one, emulated (slow).
set -eu

REPO=${TRY_UBUNTU_REPO:-antoniopicone/try-ubuntu}
DIR=${TRY_UBUNTU_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/try-ubuntu}

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

# UEFI firmware locations known to run-qemu.sh (Linux distributions).
linux_firmware_found() {
  for f in /usr/share/qemu/edk2-aarch64-code.fd /usr/share/AAVMF/AAVMF_CODE.fd \
           /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/edk2/aarch64/QEMU_CODE.fd \
           /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw; do
    [ -f "$f" ] && return 0
  done
  return 1
}

install_qemu() {
  case "$os" in
    Darwin)
      has qemu-system-aarch64 && return 0
      has brew || die "QEMU is missing and Homebrew isn't installed: see https://brew.sh, then run this again"
      say "Installing QEMU (brew install qemu)"
      brew install qemu ;;
    Linux)
      has qemu-system-aarch64 && linux_firmware_found && return 0
      say "Installing QEMU and the aarch64 UEFI firmware"
      if has apt-get; then
        sudo_run apt-get update -qq
        sudo_run apt-get install -y qemu-system-arm qemu-efi-aarch64 qemu-utils qemu-system-gui
      elif has dnf; then
        sudo_run dnf install -y qemu-system-aarch64 edk2-aarch64 qemu-img qemu-ui-gtk
      elif has pacman; then
        sudo_run pacman -S --needed --noconfirm qemu-system-aarch64 edk2-aarch64 qemu-img qemu-ui-gtk
      else
        die "install qemu-system-aarch64 and the aarch64 UEFI firmware (edk2/AAVMF) with your package manager, then run this again"
      fi ;;
  esac
  has qemu-system-aarch64 || die "qemu-system-aarch64 still not found after installing QEMU"
}

main() {
  os=$(uname -s)
  case "$os" in
    Darwin|Linux) ;;
    *) die "unsupported OS: $os (macOS and Linux only; on Windows use WSL)" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *) die "unsupported CPU: $(uname -m)" ;;
  esac
  has curl || die "curl is required"
  has bash || die "bash is required (run-qemu.sh is a bash script)"

  # /releases/latest redirects to /releases/tag/<tag>: no API call, no rate limit.
  tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") ||
    die "can't reach github.com/$REPO"
  tag=${tag##*/}
  case "$tag" in ''|latest|releases) die "$REPO has no release yet" ;; esac
  base="https://github.com/$REPO/releases/download/$tag"

  dist="$DIR/dist"
  mkdir -p "$dist"
  sums=$(curl -fsSL "$base/SHA256SUMS") || die "no SHA256SUMS in release $tag"

  iso="ubuntu-live-$arch.iso"
  if ! printf '%s\n' "$sums" | grep -q " \*\{0,1\}$iso\$"; then
    iso=ubuntu-live-arm64.iso
    printf '%s\n' "$sums" | grep -q " \*\{0,1\}$iso\$" || die "release $tag has no ISO"
  fi
  if [ "$iso" = ubuntu-live-arm64.iso ] && [ "$arch" != arm64 ]; then
    warn "there is no $arch ISO: QEMU will emulate arm64 without hardware acceleration, so it will be slow"
  fi
  expected=$(printf '%s\n' "$sums" | grep " \*\{0,1\}$iso\$" | cut -d' ' -f1)

  install_qemu
  if [ "$os" = Linux ] && [ "$arch" = arm64 ] && [ -e /dev/kvm ] && [ ! -w /dev/kvm ]; then
    warn "/dev/kvm isn't writable: add yourself to the kvm group (sudo usermod -aG kvm \$USER, then log in again) for hardware acceleration"
  fi

  # The ISO, unless this release's is already there.
  stamp="$dist/$iso.release"
  current=$(cat "$stamp" 2>/dev/null || true)
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
    if [ -n "$current" ] && [ -f "$dist/persist.qcow2" ]; then
      mv "$dist/persist.qcow2" "$dist/persist-$current.qcow2"
      say "The persistent disk of $current only works with its ISO: moved to $dist/persist-$current.qcow2"
    fi
  fi

  # run-qemu.sh from the same tag as the ISO.
  curl -fsSL -o "$DIR/run-qemu.sh" "https://raw.githubusercontent.com/$REPO/$tag/run-qemu.sh" ||
    die "can't download run-qemu.sh"
  chmod +x "$DIR/run-qemu.sh"

  say "Booting Ubuntu Live $tag (Ctrl-A X in this terminal quits QEMU)"
  # Under curl | sh stdin is the script: QEMU's serial console needs the terminal.
  if { : </dev/tty; } 2>/dev/null; then
    exec bash "$DIR/run-qemu.sh" --iso "$dist/$iso" "$@" </dev/tty
  fi
  exec bash "$DIR/run-qemu.sh" --iso "$dist/$iso" "$@"
}

# In a function, so sh has read the whole script before anything runs.
main "$@"

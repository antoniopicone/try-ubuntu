#!/bin/sh
# Downloads the live ISO from the latest GitHub release, gets QEMU and boots
# the ISO with run-qemu.sh. Or, with --on-usb, builds the ISO for real
# computers and writes it to a USB stick. Meant to be piped into sh:
#
#   curl -fsSL https://raw.githubusercontent.com/antoniopicone/try-ubuntu/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --lang de_DE --no-persist
#   curl -fsSL .../install.sh | sh -s -- --rebuild
#   curl -fsSL .../install.sh | sh -s -- --arch x86 --on-usb
#   curl -fsSL .../install.sh | sh -s -- --system-qemu
#
# --arch arm|x86: the ISO's architecture (default: this computer's). An ISO
# runs accelerated on a computer of its own architecture (an x86 ISO on an
# x86 Linux, an arm64 one on Apple Silicon or an arm64 Linux), and emulated
# (slow) on the other.
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
# hours for the other architecture, emulated: x86 on Apple Silicon, through
# qemu-user on Linux). Then it lists the USB disks, asks which one to erase, asks
# again, and writes the ISO to it. Other arguments go to build.sh (--xkb it).
# The computer must boot it with Secure Boot off (Limine isn't signed).
#
# QEMU: the release's build (qemu/build.sh), in $TRY_UBUNTU_DIR/dist. On
# Apple Silicon, for arm64 ISOs (GPU acceleration and nested
# virtualization); on Linux, x86 or arm64, for ISOs of both architectures
# (GPU acceleration; nothing to install, no root). Otherwise Homebrew's on
# a Mac, and the distribution's on a Linux where the release's doesn't
# start (it needs glibc 2.35 and the desktop's libraries: GTK 3...).
# --system-qemu: never the release's build, always Homebrew's or the
# distribution's (installed with apt, dnf or pacman, with its GTK window,
# OpenGL, virtio GPU and sound modules).
#
# On a terminal it shows the logo and its steps as a list: a dot for those
# to come, a spinner for the one running, a tick for those done. What the
# commands print goes to $TRY_UBUNTU_DIR/install.log, and its last line
# next to the spinner. Without a terminal on stderr (a pipe, a file) the
# steps are plain lines, with the commands' output between them.
set -eu

REPO=${TRY_UBUNTU_REPO:-antoniopicone/try-ubuntu}
DIR=${TRY_UBUNTU_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/try-ubuntu}
# This script's own checkout, when it's run from one (not piped)
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P || true)

has()  { command -v "$1" >/dev/null 2>&1; }

# --- the screen ----------------------------------------------------------------
#
# plan names the steps, ui_begin draws them, step starts the next one (the
# one before is done), note adds a few words to its line, finish ends the
# list. File descriptor 3 is the terminal; while the list is on, 1 and 2 are
# the log. The list is redrawn from the line under it, where the cursor
# stays: nothing else may write to the terminal meanwhile (questions get
# their room with ui_pause).

exec 3>&2
esc=$(printf '\033') cr=$(printf '\r')
ui=0 nsteps=0 cur=0 open=0 below=0 paused=0 spin_pid='' step_note='' error=''
iso_size=0 log_mark=0
# curl's progress: a bar on the terminal, its meter in the log
meter=--progress-bar
c_reset='' c_bold='' c_dim='' c_red='' c_green='' c_yellow='' c_blue=''
if [ -z "${NO_COLOR:-}" ]; then
  c_reset="${esc}[0m" c_bold="${esc}[1m" c_dim="${esc}[2m" c_red="${esc}[31m"
  c_green="${esc}[32m" c_yellow="${esc}[33m" c_blue="${esc}[34m"
fi

say() {
  if [ "$ui" = 1 ]; then printf '==> %s\n' "$*" >&2
  else printf '%s==> %s%s\n' "$c_bold" "$*" "$c_reset" >&2; fi
}

warn() {
  if [ "$ui" = 1 ]; then
    printf 'warning: %s\n' "$*" >&2
    ui_below "$c_yellow!$c_reset" "$*"
  else
    printf '%swarning:%s %s\n' "$c_yellow" "$c_reset" "$*" >&2
  fi
}

# With the list on, ui_exit shows the error (the EXIT trap).
die() {
  if [ "$ui" = 1 ]; then error=$*
  else printf '%serror:%s %s\n' "$c_red" "$c_reset" "$*" >&2; fi
  exit 1
}

is_number() { case $1 in ''|*[!0-9]*) return 1 ;; esac; }

fmt_time() {
  if [ "$1" -ge 3600 ]; then printf '%d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60))
  else printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); fi
}

plan() {
  for label do
    nsteps=$((nsteps + 1))
    eval "step_$nsteps=\$label"
  done
}

# A channel of the 256-color cube, for terminals without 24-bit colors.
cube() {
  if [ "$1" -lt 48 ]; then echo 0
  elif [ "$1" -lt 115 ]; then echo 1
  else echo $((($1 - 35) / 40)); fi
}

# The glyph of assets/try-ubuntu-app.svg (a desktop screen and the penguin
# in front of it) in ASCII, in the colors of the icon's screen, aubergine
# to orange. $1: what is about to happen, written next to it.
ui_logo() {
  n=0
  while IFS= read -r line; do
    r=$((165 + 81 * n / 12)) g=$((60 + 72 * n / 12)) b=$((150 - 71 * n / 12))
    n=$((n + 1))
    if [ -z "$c_reset" ]; then color=''
    elif [ "${COLORTERM:-}" = truecolor ] || [ "${COLORTERM:-}" = 24bit ]; then
      color="${esc}[38;2;$r;$g;${b}m"
    else
      color="${esc}[38;5;$((16 + 36 * $(cube $r) + 6 * $(cube $g) + $(cube $b)))m"
    fi
    case $n in
      6) side="${c_bold}try-ubuntu$c_reset" ;;
      7) side="$c_dim$1$c_reset" ;;
      *) side='' ;;
    esac
    printf '  %s%-31s%s%s\n' "$color" "$line" "$c_reset" "$side" >&3
  done <<'EOF'
 .#######################.
 ##                     ##
 ##  =================  ##
 ##  #                  ##
 ##  #                  ##
 ##  #                  ##
 ##                     ##
 '############  _.#####._
           ## .d#########b.
             d##P  9#P  9##b
     ####### ###b  d#b  d###
             ####P"   "9####
             "#####___#####"
EOF
}

# The list, when stderr is a terminal with room for it. $1: see ui_logo.
ui_begin() {
  [ -t 2 ] && [ "${TERM:-dumb}" != dumb ] || return 0
  size=$(stty size </dev/tty 2>/dev/null) || return 0
  rows=${size% *} cols=${size#* }
  is_number "$rows" && is_number "$cols" || return 0
  [ "$rows" -ge $((nsteps + 4)) ] && [ "$cols" -ge 50 ] || return 0
  log="$DIR/install.log"
  mkdir -p "$DIR" 2>/dev/null && { true > "$log"; } 2>/dev/null || return 0

  case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*)
      g_frames='⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏' g_todo='•' g_done='✓' g_skip='–' g_fail='✗' g_go='▸' ;;
    *)
      g_frames='| / - \' g_todo='.' g_done='+' g_skip='-' g_fail='x' g_go='>' ;;
  esac
  # A frame every tenth of a second, where sleep takes fractions
  tick=0.1 every=10
  sleep 0.1 2>/dev/null || tick=1 every=1

  # No line wrapping (?7l) while drawing: what doesn't fit is cut
  printf '\033[?25l\033[?7l\n' >&3
  if [ "$rows" -ge $((nsteps + 16)) ]; then ui_logo "$1"
  else printf '  %stry-ubuntu%s  %s%s%s\n' "$c_bold" "$c_reset" "$c_dim" "$1" "$c_reset" >&3; fi
  printf '\n' >&3
  i=0
  while [ "$i" -lt "$nsteps" ]; do
    i=$((i + 1))
    eval "label=\$step_$i"
    printf '  %s%s %s%s\n' "$c_dim" "$g_todo" "$label" "$c_reset" >&3
  done
  printf '\033[?7h' >&3
  exec 4>&1 >>"$log" 2>&1
  ui=1 meter=''
}

# Line $1 of the list becomes $2.
ui_line() {
  up=$((nsteps - $1 + 1 + below))
  printf '\033[?7l\033[%dA\r\033[2K%s\033[%dB\r\033[?7h' "$up" "$2" "$up" >&3
}

# A line under the list, to stay there: $1 its mark, $2 its text.
ui_below() {
  spinning=$spin_pid
  spin_stop
  printf '  %s %s\n' "$1" "$2" >&3
  below=$((below + (${#2} + 4 + cols - 1) / cols))
  [ -z "$spinning" ] || spin_start
}

# The last thing the running step printed, for its line: without colors and
# what a terminal can't count on, and with curl's meter and dd's progress
# made readable.
detail() {
  d=$(tail -c 2048 "$log" 2>/dev/null | tr '\r\t' '\n ' |
    LC_ALL=C sed -e "s/$esc\[[0-9;?]*[A-Za-z]//g" -e 's/^ *//' -e '/^$/d' | tail -n 1 |
    LC_ALL=C tr -cd '\40-\176')
  case $d in '### '*) return 0 ;; esac
  d=${d#==> }
  set -- $d
  if [ $# -eq 12 ] && is_number "$1"; then
    # curl: % total % received % sent, average speeds, times, speed
    case "$2:${11}" in
      0:*) d='' ;;
      *:*-*) d="$1% of $2, ${12}/s" ;;
      *:*:*:*) d="$1% of $2, ${12}/s, ${11} left" ;;
    esac
  elif [ "${2:-}" = bytes ] && is_number "$1" && [ "$iso_size" -gt 0 ]; then
    d="$(($1 * 100 / iso_size))%, ${d##*, }"
  fi
  printf '%s' "$d"
}

# The running step's line, in the background until spin_stop (or until
# this script is gone): the spinner,
# the time it's taking, and its last line of output.
spin() {
  set +e -f
  eval "label=\$step_$cur"
  head="$c_bold$label$c_reset${step_note:+  $c_dim$step_note$c_reset}"
  room=$((cols - ${#label} - ${#step_note} - 8))
  [ "$room" -gt 0 ] || room=0
  n=0 status=''
  while :; do
    for frame in $g_frames; do
      [ ! -e "$log.stop" ] || exit 0
      if [ $((n % every)) -eq 0 ]; then
        kill -0 $$ 2>/dev/null || exit 0
        status=$(printf "%.${room}s" "$(fmt_time $(($(date +%s) - started)))  $(detail)")
      fi
      n=$((n + 1))
      ui_line "$cur" "  $c_blue$frame$c_reset $head  $c_dim$status$c_reset"
      sleep "$tick"
    done
  done
}

spin_start() {
  rm -f "$log.stop"
  spin &
  spin_pid=$!
}

# With a file, not a signal: dash loses the one that reaches a subshell
# before it has reset the traps (the spinner of a step that has just begun).
spin_stop() {
  [ -n "$spin_pid" ] || return 0
  { true > "$log.stop"; } 2>/dev/null || kill "$spin_pid" 2>/dev/null || true
  wait "$spin_pid" 2>/dev/null || true
  rm -f "$log.stop"
  spin_pid=''
}

# The current step's line as it stays: done, skip, fail, or go for the one
# the list hands the terminal over to.
ui_mark() {
  open=0
  eval "label=\$step_$cur"
  took=$(($(date +%s) - started))
  words=$step_note
  [ "$took" -lt 10 ] || words="${words:+$words, }$(fmt_time "$took")"
  room=$((cols - ${#label} - 6))
  [ "$room" -gt 0 ] || room=0
  words=$(printf "%.${room}s" "$words")
  case $1 in
    done) line="  $c_green$g_done$c_reset $label" ;;
    skip) line="  $c_dim$g_skip $label$c_reset" ;;
    fail) line="  $c_red$g_fail$c_reset $c_bold$label$c_reset" ;;
    go)   line="  $c_blue$g_go$c_reset $c_bold$label$c_reset" ;;
  esac
  ui_line "$cur" "$line${words:+  $c_dim$words$c_reset}"
}

ui_next() {
  spin_stop
  [ "$open" = 0 ] || ui_mark done
  cur=$((cur + 1)) open=1 step_note='' started=$(date +%s)
  eval "label=\$step_$cur"
  printf '\n### %s\n' "$label" >&2
  log_mark=$(wc -l < "$log" | tr -d ' ')
}

# The next step of the plan starts.
step() {
  if [ "$ui" = 1 ]; then
    ui_next
    spin_start
  else
    cur=$((cur + 1))
    eval "say \"\$step_$cur\""
  fi
}

# The next step of the plan isn't needed: $1 says why.
skip() {
  if [ "$ui" = 1 ]; then
    ui_next
    step_note=$1
    ui_mark skip
  else
    cur=$((cur + 1))
  fi
}

# A few words on the running step's line, which stay when it's done.
note() {
  if [ "$ui" = 1 ]; then
    step_note=$1
    [ -z "$spin_pid" ] || { spin_stop; spin_start; }
  else
    printf '    %s\n' "$1" >&2
  fi
}

# Room under the list for questions and their answers, $1 lines: scrolled
# into view now, since the place ui_resume wipes from is a spot on the
# screen, lost if it scrolls later.
ui_pause() {
  [ "$ui" = 1 ] || return 0
  spin_stop
  eval "label=\$step_$cur"
  ui_line "$cur" "  $c_blue?$c_reset $c_bold$label$c_reset"
  lines=$1 room=$((rows - nsteps - below - 1))
  [ "$lines" -le "$room" ] || lines=$room
  [ "$lines" -ge 1 ] || lines=1
  i=0
  while [ "$i" -lt "$lines" ]; do
    printf '\n' >&3
    i=$((i + 1))
  done
  printf '\033[%dA%s7\033[?25h' "$lines" "$esc" >&3
  paused=1
}

ui_resume() {
  [ "$ui" = 1 ] || return 0
  printf '%s8\033[J\033[?25l' "$esc" >&3
  paused=0
  spin_start
}

ui_close() {
  printf '\033[?25h\n' >&3
  exec 1>&4 2>&3 4>&-
  ui=0
}

# The list is over, its last step done (or $1, see ui_mark): the terminal
# goes to what comes next.
finish() {
  [ "$ui" = 1 ] || return 0
  spin_stop
  [ "$open" = 0 ] || ui_mark "${1:-done}"
  ui_close
}

# On exit with the list still on: the step that was running failed. Its last
# lines of output follow, without the progress meters' rewrites.
ui_exit() {
  [ "$ui" = 1 ] || return 0
  set +e
  spin_stop
  [ "$paused" = 0 ] || printf '%s8\033[J' "$esc" >&3
  if [ "$open" = 1 ]; then
    [ "$1" -lt 129 ] || step_note=interrupted
    if [ "$1" -eq 0 ]; then ui_mark done; else ui_mark fail; fi
  fi
  ui_close
  [ "$1" -ne 0 ] && [ "$1" -lt 129 ] || return 0
  printf '%s' "$c_dim" >&2
  tail -n +"$((log_mark + 1))" "$log" |
    LC_ALL=C sed -e "s/$cr\$//" -e "s/.*$cr//" -e "s/$esc\[[0-9;?]*[A-Za-z]//g" \
      -e '/^ *$/d' -e '/^### /d' | tail -n 8 | sed 's/^/    /' >&2
  printf '%s  %serror:%s %s\n  The whole output is in %s\n' "$c_reset" "$c_red" "$c_reset" \
    "${error:-this step failed (exit status $1)}" "$log" >&2
}
trap 'ui_exit $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# sudo's password, asked under the list before the command that needs it:
# sudo would ask on the line the spinner redraws from.
sudo_ready() {
  [ "$ui" = 1 ] && has sudo || return 0
  sudo -n true 2>/dev/null && return 0
  was_paused=$paused
  [ "$was_paused" = 1 ] || ui_pause 4
  sudo -v -p '  Password for sudo: ' 2>&3 || die "sudo didn't get the password"
  [ "$was_paused" = 1 ] || ui_resume
}

sudo_run() {
  if [ "$(id -u)" -eq 0 ]; then "$@"
  elif has sudo; then sudo_ready; sudo "$@"
  else die "run as root or install sudo: $*"; fi
}

sha256() {
  if has sha256sum; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# The answer to a question, from the terminal even under curl | sh. It
# fails without a terminal: its caller dies (here it's in a subshell).
ask() {
  printf '%s ' "$1" >&3
  read -r answer </dev/tty || return 1
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

# The distribution's QEMU, with what run-qemu.sh shows the desktop with: the
# firmware, a GTK window and the virtio GPU with OpenGL (Fedora and Arch
# have them as packages of their own).
linux_qemu_complete() {
  has "$qemu" && linux_firmware_found || return 1
  gpu=virtio-gpu-gl-pci
  [ "$arch" = amd64 ] && gpu=virtio-vga-gl
  "$qemu" -display help 2>/dev/null | grep -qx gtk || return 1
  "$qemu" -device help 2>/dev/null | grep -q "name \"$gpu\""
}

# The release's QEMU for this computer (see qemu/build.sh), unless this
# release's is already there: Apple Silicon's runs arm64 ISOs, Linux's
# both. Returns 1 when the release has none, or when it doesn't start here
# (Linux's uses the desktop's libraries).
install_qemu_release() {
  case "$os:$host" in
    Darwin:arm64)
      [ "$arch" = arm64 ] || return 1
      qemu_rt=qemu-macos-arm64 qemu_for='Apple Silicon' ;;
    Linux:*) qemu_rt=qemu-linux-$host qemu_for="Linux ($host)" ;;
    *) return 1 ;;
  esac
  qemu_tgz=$qemu_rt.tar.gz
  printf '%s\n' "$sums" | grep -q " \*\{0,1\}$qemu_tgz\$" || return 1
  qemu_stamp="$dist/$qemu_rt.release"
  if [ "$(cat "$qemu_stamp" 2>/dev/null || true)" = "$tag" ]; then
    # Downloaded already: without it, it didn't start here
    [ -x "$dist/$qemu_rt/bin/$qemu" ] || return 1
    note "the release's build for $qemu_for, already here"
    return 0
  fi
  note "the release's build for $qemu_for"
  tmp=$(mktemp -d "$dist/.qemu.XXXXXX")
  curl -fL $meter -o "$tmp/$qemu_tgz" "$base/$qemu_tgz" </dev/null || {
    rm -rf "$tmp"; die "QEMU download failed; run this again"; }
  if [ "$(sha256 "$tmp/$qemu_tgz")" != "$(printf '%s\n' "$sums" | grep " \*\{0,1\}$qemu_tgz\$" | cut -d' ' -f1)" ]; then
    rm -rf "$tmp"; die "checksum mismatch for $qemu_tgz; run this again"
  fi
  tar -xzf "$tmp/$qemu_tgz" -C "$tmp"
  rm -rf "$dist/$qemu_rt"
  printf '%s\n' "$tag" > "$qemu_stamp"
  if ! "$tmp/$qemu_rt/bin/$qemu" --version >&2; then
    rm -rf "$tmp"
    warn "the release's QEMU doesn't start on this system: using the distribution's"
    return 1
  fi
  mv "$tmp/$qemu_rt" "$dist/$qemu_rt"
  rm -rf "$tmp"
}

# --rebuild: everything downloaded from the releases, and the caches. Not
# the persistent disks (persist*.qcow2) nor the UEFI variables (efivars*.fd).
purge_downloads() {
  note "in $dist"
  rm -rf "$dist"/*.iso "$dist"/*.iso.*.part "$dist"/*.release \
    "$dist/qemu-macos-arm64" "$dist"/qemu-linux-* "$dist"/.qemu.* "$dist"/.kernel-* "$dist"/.app-* \
    "$DIR/run-qemu.sh" "$DIR/try-ubuntu.icns"
}

install_qemu() {
  qemu=qemu-system-aarch64
  [ "$arch" = amd64 ] && qemu=qemu-system-x86_64
  if [ "$system_qemu" = 0 ] && install_qemu_release; then return 0; fi
  case "$os" in
    Darwin)
      if has "$qemu"; then
        note "already installed"
        return 0
      fi
      has brew || die "QEMU is missing and Homebrew isn't installed: see https://brew.sh, then run this again"
      note "brew install qemu"
      brew install qemu ;;
    Linux)
      if linux_qemu_complete; then
        note "already installed"
        return 0
      fi
      note "with the $arch UEFI firmware"
      if has apt-get; then
        sudo_run apt-get update -qq
        if [ "$arch" = amd64 ]; then
          sudo_run apt-get install -y qemu-system-x86 ovmf qemu-utils qemu-system-gui
        else
          sudo_run apt-get install -y qemu-system-arm qemu-efi-aarch64 qemu-utils qemu-system-gui
        fi
      # Fedora and Arch split QEMU up: the window, OpenGL, the sound
      # systems and each flavour of the virtio GPU are packages
      elif has dnf; then
        set -- qemu-img qemu-ui-gtk qemu-ui-opengl qemu-audio-pipewire qemu-audio-pa qemu-audio-alsa
        if [ "$arch" = amd64 ]; then
          sudo_run dnf install -y qemu-system-x86 edk2-ovmf "$@" \
            qemu-device-display-virtio-vga qemu-device-display-virtio-vga-gl
        else
          sudo_run dnf install -y qemu-system-aarch64 edk2-aarch64 "$@" \
            qemu-device-display-virtio-gpu-pci qemu-device-display-virtio-gpu-pci-gl
        fi
      elif has pacman; then
        set -- qemu-img qemu-ui-gtk qemu-ui-opengl qemu-audio-pipewire qemu-audio-pa qemu-audio-alsa \
          qemu-hw-display-virtio-gpu qemu-hw-display-virtio-gpu-pci \
          qemu-hw-display-virtio-gpu-gl qemu-hw-display-virtio-gpu-pci-gl
        if [ "$arch" = amd64 ]; then
          sudo_run pacman -S --needed --noconfirm qemu-system-x86 edk2-ovmf "$@" \
            qemu-hw-display-virtio-vga qemu-hw-display-virtio-vga-gl
        else
          sudo_run pacman -S --needed --noconfirm qemu-system-aarch64 edk2-aarch64 "$@"
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
    note "the checkout in $src"
    return
  fi
  src="$DIR/src/$tag"
  note "$tag"
  if [ ! -f "$src/build.sh" ]; then
    rm -rf "$src"
    mkdir -p "$src"
    curl -fsSL "https://github.com/$REPO/archive/refs/tags/$tag.tar.gz" </dev/null |
      tar -xzf - -C "$src" --strip-components=1 || { rm -rf "$src"; die "can't download the sources of $tag"; }
  fi
}

# podman, with a machine able to build (on a Mac: rootful, for loop
# devices; room and memory for compiling GNOME). For an ISO of the other
# architecture its containers are emulated: the podman machine can, a Linux
# needs qemu-user registered with binfmt_misc.
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
      if ! has podman; then
        say "Installing podman"
        if has apt-get; then sudo_run apt-get update -qq && sudo_run apt-get install -y podman
        elif has dnf; then sudo_run dnf install -y podman
        elif has pacman; then sudo_run pacman -S --needed --noconfirm podman
        else die "install podman with your package manager, then run this again"; fi
      fi
      emulator=qemu-aarch64
      [ "$arch" = amd64 ] && emulator=qemu-x86_64
      if [ "$arch" != "$host" ] && ! ls /proc/sys/fs/binfmt_misc/"$emulator"* >/dev/null 2>&1; then
        say "Installing qemu-user (to run $arch containers)"
        if has apt-get; then
          # qemu-user-static became qemu-user and qemu-user-binfmt (Debian 13, Ubuntu 25.04)
          sudo_run apt-get update -qq
          if apt-cache show qemu-user-binfmt >/dev/null 2>&1; then sudo_run apt-get install -y qemu-user-binfmt
          else sudo_run apt-get install -y qemu-user-static; fi
        elif has dnf; then sudo_run dnf install -y qemu-user-static
        elif has pacman; then sudo_run pacman -S --needed --noconfirm qemu-user-static qemu-user-static-binfmt
        else die "install qemu-user-static (binfmt_misc) with your package manager, then run this again"; fi
        ls /proc/sys/fs/binfmt_misc/"$emulator"* >/dev/null 2>&1 ||
          sudo_run systemctl restart systemd-binfmt.service || true
      fi ;;
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
  step
  disks=$(list_usb)
  [ -n "$disks" ] || die "no USB disk found: plug one in (at least $(human "$iso_size")) and run this again"
  ui_pause $(($(printf '%s\n' "$disks" | wc -l) + 9))
  printf '\n  USB disks:\n' >&3
  i=0
  printf '%s\n' "$disks" | while IFS='|' read -r dev bytes desc; do
    i=$((i + 1))
    printf '    %d) %s  %s  %s\n' "$i" "$dev" "$(human "$bytes")" "$desc" >&3
  done
  choice=$(ask "  Which one gets the live system (number, or Enter to stop)?") ||
    die "no terminal to answer from"
  [ -n "$choice" ] || die "stopped: nothing was written"
  case "$choice" in *[!0-9]*) die "not a number: $choice" ;; esac
  line=$(printf '%s\n' "$disks" | sed -n "${choice}p")
  [ -n "$line" ] || die "no disk number $choice"
  dev=${line%%|*}; rest=${line#*|}; bytes=${rest%%|*}; desc=${rest#*|}
  [ "$bytes" -ge "$iso_size" ] || die "$dev is too small ($(human "$bytes")) for the ISO ($(human "$iso_size"))"
  printf '  %s!%s everything on %s (%s, %s) will be erased\n' "$c_yellow" "$c_reset" \
    "$dev" "$desc" "$(human "$bytes")" >&3
  confirm=$(ask "  Type $dev to erase it and write the live system:") ||
    die "no terminal to answer from"
  [ "$confirm" = "$dev" ] || die "stopped: nothing was written"
  [ "$(id -u)" -eq 0 ] || sudo_ready
  ui_resume
  note "$dev, $desc, $(human "$bytes")"

  step
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
  finish
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
  step
  get_sources
  step
  get_podman
  iso="$src/dist/ubuntu-live-$arch-hardware.iso"
  stamp="$iso.release"
  # From the release's sources, a new release means a new build; from a
  # checkout, only --rebuild or a missing ISO does
  outdated=0
  [ "$src" != "$SELF_DIR" ] && [ "$(cat "$stamp" 2>/dev/null || true)" != "$tag" ] && outdated=1
  step
  if [ "$rebuild" = 1 ] || [ ! -f "$iso" ] || [ "$outdated" = 1 ]; then
    note "$arch, $tag"
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
    note "$arch, already built for $tag"
  fi
  write_usb "$iso"
}

main() {
  # --rebuild, --arch, --on-usb and --system-qemu are ours; everything else
  # goes to run-qemu.sh (or with --on-usb to build.sh; after --, to QEMU,
  # untouched).
  rebuild=0 passthrough=0 on_usb=0 arch_opt='' expect_arch=0 system_qemu=0
  for arg do
    shift
    if [ "$expect_arch" = 1 ]; then
      arch_opt=$arg expect_arch=0
      continue
    fi
    case "$passthrough:$arg" in
      0:--rebuild) rebuild=1 ;;
      0:--on-usb) on_usb=1 ;;
      0:--system-qemu) system_qemu=1 ;;
      0:--arch) expect_arch=1 ;;
      0:--arch=*) arch_opt=${arg#--arch=} ;;
      0:--) passthrough=1; set -- "$@" "$arg" ;;
      *) set -- "$@" "$arg" ;;
    esac
  done
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
  # This computer's architecture, unless --arch says otherwise
  case "${arch_opt:-$host}" in
    arm|arm64|aarch64) arch=arm64 arch_opt=arm ;;
    x86|x86_64|amd64) arch=amd64 arch_opt=x86 ;;
    *) die "--arch is arm or x86, not '$arch_opt'" ;;
  esac
  has curl || die "curl is required"
  has bash || die "bash is required (run-qemu.sh and build.sh are bash scripts)"

  plan "Find the latest release"
  if [ "$on_usb" = 1 ]; then
    plan "Get the sources" "Get podman" "Build the ISO for real computers" \
      "Choose the USB stick" "Write the live system to it"
    ui_begin "a live USB stick for a real computer ($arch_opt)"
  else
    [ "$rebuild" = 0 ] || plan "Delete the downloads and the caches"
    plan "Get QEMU" "Download the ISO" "Check the SHA-256" "Get the launcher" "Boot Ubuntu Live"
    ui_begin "the live session in QEMU ($arch_opt)"
  fi

  step
  # /releases/latest redirects to /releases/tag/<tag>: no API call, no rate limit.
  tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") ||
    die "can't reach github.com/$REPO"
  tag=${tag##*/}
  case "$tag" in ''|latest|releases) die "$REPO has no release yet" ;; esac
  base="https://github.com/$REPO/releases/download/$tag"
  note "$tag"

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
  if [ "$rebuild" = 1 ]; then
    step
    purge_downloads
  fi

  step
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
    step
    note "$iso"
    curl -fL $meter -C - -o "$part" "$base/$iso" </dev/null ||
      die "download failed; run this again to resume it"
    step
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
      warn "the persistent disk of $current only works with its ISO: moved to $dist/$old"
    fi
  else
    step
    note "$iso, already here"
    skip "done when it was downloaded"
  fi

  # run-qemu.sh from the same tag as the ISO.
  step
  curl -fsSL -o "$DIR/run-qemu.sh" "https://raw.githubusercontent.com/$REPO/$tag/run-qemu.sh" ||
    die "can't download run-qemu.sh"
  chmod +x "$DIR/run-qemu.sh"
  # The Dock icon of QEMU's window on a Mac (run-qemu.sh does without it too)
  [ "$(uname -s)" != Darwin ] ||
    curl -fsSL -o "$DIR/try-ubuntu.icns" \
      "https://raw.githubusercontent.com/$REPO/$tag/assets/try-ubuntu.icns" 2>/dev/null ||
    rm -f "$DIR/try-ubuntu.icns"

  # Not the release's build, should an earlier run have left one here
  [ "$system_qemu" = 0 ] || set -- --qemu "$(command -v "$qemu")" "$@"

  step
  note "$tag, close the window to quit"
  finish go
  # Under curl | sh stdin is the script: QEMU's serial console (--headless,
  # --serial) needs the terminal. In a subshell: without a terminal, dash
  # exits on the failed redirection.
  if ( : </dev/tty ) 2>/dev/null; then
    exec bash "$DIR/run-qemu.sh" --iso "$dist/$iso" --arch "$arch_opt" "$@" </dev/tty 3>&-
  fi
  exec bash "$DIR/run-qemu.sh" --iso "$dist/$iso" --arch "$arch_opt" "$@" 3>&-
}

# In a function, so sh has read the whole script before anything runs.
main "$@"

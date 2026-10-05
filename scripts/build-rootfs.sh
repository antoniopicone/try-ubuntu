#!/usr/bin/env bash
# Builds the live root filesystem in $ROOTFS: a hand-picked minimal Ubuntu
# ($ARCH: arm64 or amd64) via debootstrap; for QEMU the "virtual" kernel
# pruned to what a VM needs, for real computers ($HARDWARE=1) the generic
# kernel with all of linux-firmware; Plymouth, Nautilus, Brave Origin, Tailscale, podman, Python (pip, uv),
# zsh with the pure prompt and eza, snapper, Flatpak with Flathub, fonts,
# apfs-fuse (built by build-apfs-fuse.sh), and the btrfslive initramfs boot
# script from overlay/. The desktop (GNOME with GDM) comes from
# scripts/desktop-gnome.sh.
set -euo pipefail

: "${ROOTFS:?}" "${OVERLAY:?}" "${SUITE:?}" "${MIRROR:?}" "${WORK:?}" "${APFS_FUSE_OUT:?}" "${ICLOUD_LINUX_OUT:?}"
: "${ISO_LABEL:?}" "${PERSIST_SERIAL:?}"
: "${LIVE_USER:=ubuntu}" "${LIVE_PASSWORD:=ubuntu}" "${LIVE_HOSTNAME:=ubuntu-live}"
: "${XKB_LAYOUT:=us}"
: "${ARCH:=arm64}" "${HARDWARE:=0}" "${EMULATED:=0}"

# Brave's package repository (Brave Origin, the browser). Its keyring holds
# three signing keys.
BRAVE_KEY_FPRS="DBF1A116C220B8C7164F98230686B78420038257 47D32A74E9A9E013A4B4926C68D513D36A73CD96 B2A3DCA350E67256740DF904DE4EC67BE4B0DCA0"
# Tailscale's package repository. Its packages are static builds, the same
# for every Ubuntu release, and new releases get their suite late: the LTS
# suite serves them all.
TAILSCALE_KEY_FPR=2596A99EAAB33821893C0A79458CA832957F5868
TAILSCALE_SUITE=resolute
# Flathub, added as a system Flatpak remote from the vendored
# scripts/flathub.flatpakrepo (which carries its key).
FLATHUB_KEY_FPR=6E5C05D979C76DAF93C081354184DD4D907A7CAE

# Tools that are not in the Ubuntu archive, pinned and checked.
UV_VERSION=0.12.21
case $ARCH in
  arm64) UV_TARGET=aarch64-unknown-linux-gnu
         UV_SHA256=030b69227b40af8c1981b7301793dc66e71ed3c796ea8688209dd268bd91ec51 ;;
  amd64) UV_TARGET=x86_64-unknown-linux-gnu
         UV_SHA256=23f02075b652bb1df64178cfae41b5caf160822e720e2663568f3f5d63bc52c0 ;;
  *) echo "unsupported ARCH: $ARCH" >&2; exit 1 ;;
esac
UV_URL="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$UV_TARGET.tar.gz"
PURE_VERSION=1.28.3
PURE_URL="https://github.com/sindresorhus/pure/archive/refs/tags/v$PURE_VERSION.tar.gz"
PURE_SHA256=738b523c59823083de490b3eb6c1116fc45c342e6b32a7d3cf05fdd0f8aa75a8
# Hack Nerd Font (Hack with the Nerd Fonts icons, for prompts and eza):
# in no Ubuntu archive.
NERD_FONTS_VERSION=3.5.1
HACK_NERD_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v$NERD_FONTS_VERSION/Hack.tar.xz"
HACK_NERD_SHA256=cdd389472e10e2261520140ff1b382b4f8a226af5fd0b2735b975d31151d9c3c
# JetBrains Mono Nerd Font (Ghostty's font), same release.
JETBRAINS_NERD_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v$NERD_FONTS_VERSION/JetBrainsMono.tar.xz"
JETBRAINS_NERD_SHA256=04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf

# fetch URL SHA256 DEST: download and verify.
fetch() {
  # A server that doesn't answer for a moment shouldn't cost a whole build
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 --connect-timeout 30 "$1" -o "$3"
  echo "$2  $3" | sha256sum -c --quiet
}

chroot_mounts=()
cleanup() {
  for ((i=${#chroot_mounts[@]}-1; i>=0; i--)); do
    umount -l "${chroot_mounts[i]}" 2>/dev/null || true
  done
}
trap cleanup EXIT

bind() { mount --bind "$1" "$2"; chroot_mounts+=("$2"); }
# check_runs DESCRIPTION CMD...: CMD (in the chroot) must succeed. In an
# emulated build (EMULATED=1: amd64 under qemu-user on an arm64 host) some
# downloaded binaries can't run at all (uv: a segfault in the emulator),
# though they're fine on the CPU they're for and checked by sha256 anyway:
# there it's only a warning. Native builds of the same files check them.
check_runs() {
  local what=$1; shift
  if in_chroot "$@" >/dev/null 2>&1; then return; fi
  if ((EMULATED)); then
    echo "    warning: $what can't be checked in an emulated build"
  else
    echo "$what isn't working" >&2; exit 1
  fi
}
in_chroot() { chroot "$ROOTFS" /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
  DEBIAN_FRONTEND=noninteractive "$@"; }

# The desktop part: desktop_repos, DESKTOP_PACKAGES, desktop_install and
# desktop_configure.
source "$(dirname "$0")/desktop-gnome.sh"

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

echo "==> debootstrap $SUITE (minbase)"
# A development release may be newer than the builder's debootstrap: every
# Ubuntu suite uses the same script (gutsy).
debootstrap_script=/usr/share/debootstrap/scripts/$SUITE
[[ -e "$debootstrap_script" ]] || debootstrap_script=/usr/share/debootstrap/scripts/gutsy
debootstrap --variant=minbase --arch="$ARCH" --components=main,universe \
  "$SUITE" "$ROOTFS" "$MIRROR" "$debootstrap_script"

cat > "$ROOTFS/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates $SUITE-security
Components: main restricted universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
: > "$ROOTFS/etc/apt/sources.list"
echo 'APT::Install-Recommends "false";' > "$ROOTFS/etc/apt/apt.conf.d/90-no-recommends"
# Documentation, man pages and translations are never unpacked (see the
# file); what debootstrap already unpacked is removed in the cleanup step.
install -Dm644 "$OVERLAY/etc/dpkg/dpkg.cfg.d/01-live-excludes" \
  "$ROOTFS/etc/dpkg/dpkg.cfg.d/01-live-excludes"

bind /proc "$ROOTFS/proc"
bind /sys  "$ROOTFS/sys"
bind /dev  "$ROOTFS/dev"
bind /dev/pts "$ROOTFS/dev/pts"
mount -t tmpfs tmpfs "$ROOTFS/run"; chroot_mounts+=("$ROOTFS/run")
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf.build"
ln -sf /etc/resolv.conf.build "$ROOTFS/etc/resolv.conf"

# No services may start inside the build chroot.
printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

echo "==> Installing packages"
in_chroot apt-get update
in_chroot apt-get -y full-upgrade
# The kernel's postinst would build an initramfs for the default boot (local
# disk); installing initramfs-tools + btrfs-progs first and the overlay hooks
# before the kernel means the only initramfs built already knows btrfslive.
# btrfslive needs busybox (awk, sed, seq...) in the initramfs: from 26.10 on it
# is the "busybox" package and only a Recommends of initramfs-tools.
busybox_pkg=busybox
in_chroot apt-cache show busybox-initramfs >/dev/null 2>&1 && busybox_pkg=busybox-initramfs
in_chroot apt-get install -y initramfs-tools "$busybox_pkg" btrfs-progs util-linux zstd ca-certificates
cp -a --no-preserve=ownership "$OVERLAY/etc/initramfs-tools/." "$ROOTFS/etc/initramfs-tools/"
# This build's live medium label and persistent disk serial (btrfslive).
cat > "$ROOTFS/etc/initramfs-tools/conf.d/btrfslive" <<EOF
BTRFSLIVE_LABEL=$ISO_LABEL
BTRFSLIVE_PERSIST_SERIAL=$PERSIST_SERIAL
EOF

# Extra repositories (HTTPS, so only now that ca-certificates is installed).
# check_key FILE EXPECTED_FINGERPRINTS: the keyring holds exactly those keys.
check_key() {
  local fprs
  fprs=$(gpg --show-keys --with-colons "$1" | awk -F: '/^pub:/ { getline; print $10 }' | sort | xargs)
  [[ "$fprs" == "$(tr ' ' '\n' <<<"$2" | sort | xargs)" ]] || {
    echo "${1##*/} has keys '$fprs', expected '$2'" >&2
    exit 1
  }
}
# Brave, laid out as its own install instructions do: the keyring where its
# brave-keyring package keeps it (which then takes it over and updates it)
# and the .sources file name that package looks for. With any other name it
# would make Brave's keys trusted for every repository.
key="$OVERLAY/etc/apt/keyrings/brave-browser-archive-keyring.gpg"
check_key "$key" "$BRAVE_KEY_FPRS"
install -Dm644 "$key" "$ROOTFS/usr/share/keyrings/brave-browser-archive-keyring.gpg"
cat > "$ROOTFS/etc/apt/sources.list.d/brave-browser-release.sources" <<EOF
Types: deb
URIs: https://brave-browser-apt-release.s3.brave.com
Suites: stable
Components: main
Architectures: $ARCH
Signed-By: /usr/share/keyrings/brave-browser-archive-keyring.gpg
EOF
# brave-origin's maintainer scripts come from Chrome's: unless told not to,
# its postinst (and its daily cron job) adds a repository of its own, and
# today's points at Google Chrome's (dl.google.com) with Google's key.
# The repository above is the one: no other.
cat > "$ROOTFS/etc/default/brave-origin" <<EOF
repo_add_once="false"
repo_reenable_on_distupgrade="false"
EOF
# Only Brave's own packages come from its repository.
cat > "$ROOTFS/etc/apt/preferences.d/brave-only" <<EOF
Package: *
Pin: release o=Brave Software
Pin-Priority: 1

Package: brave-origin brave-keyring
Pin: release o=Brave Software
Pin-Priority: 500
EOF

# Tailscale, laid out as its own install instructions do.
key="$OVERLAY/etc/apt/keyrings/tailscale-archive-keyring.gpg"
check_key "$key" "$TAILSCALE_KEY_FPR"
install -Dm644 "$key" "$ROOTFS/usr/share/keyrings/tailscale-archive-keyring.gpg"
cat > "$ROOTFS/etc/apt/sources.list.d/tailscale.list" <<EOF
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu $TAILSCALE_SUITE main
EOF

# ModemManager is never wanted (geoclue only links its client library).
cat > "$ROOTFS/etc/apt/preferences.d/no-modemmanager" <<EOF
Package: modemmanager
Pin: release *
Pin-Priority: -1
EOF
desktop_repos
in_chroot apt-get update

# Hand-picked instead of ubuntu-minimal, which drags in netplan, locales,
# console-setup, ubuntu-pro-client and friends.
packages=(
  # minimal server base
  systemd-sysv systemd-resolved systemd-timesyncd udev kmod dbus procps
  iproute2 iputils-ping netbase openssh-server sudo less nano
  # installing on a disk (install-system): partitions, the EFI system
  # partition, the firmware's boot entry
  fdisk dosfstools efibootmgr
  # boot splash (spinner: the theme GNOME/Fedora use)
  plymouth plymouth-theme-spinner
  # system services the desktops integrate with
  polkitd upower power-profiles-daemon bluez geoclue-2.0
  dbus-user-session libpam-systemd
  # file manager and browser, Brave Origin: Brave without the Rewards,
  # Wallet, VPN and AI extras (the terminal comes with the desktop)
  nautilus brave-origin
  # networking and security
  ufw tailscale avahi-daemon libnss-mdns
  # containers (rootless needs uidmap, and pasta from passt for networking)
  podman uidmap passt
  # tools (eza: ls with icons, aliased in /etc/skel/.zshrc)
  git curl wget eza
  # the questions packages ask when installed from a terminal (debconf's
  # dialogs: without it, a warning and plain text questions)
  whiptail
  # development: Python (pip, venv; uv is installed below), zsh
  python3-pip python3-venv zsh
  # Flatpak (Flathub is added below; GNOME Software's plugin comes with the
  # desktop)
  flatpak
  # FUSE, for apfs-fuse (installed below; Mac disks, read-only)
  fuse3
  # fonts: metric-compatible with Arial/Times/Courier (Liberation) and with
  # Calibri/Cambria (Carlito/Caladea), so Office documents keep their
  # layout; JetBrains Mono. Hack Nerd Font is installed below.
  fonts-liberation fonts-crosextra-carlito fonts-crosextra-caladea fonts-jetbrains-mono
  # btrfs snapshots of / (the @ subvolume)
  snapper
  # AI (live-ai): crashes kept for the agents to explain (systemd-coredump,
  # and gdb to read them), YAML for the knowledge base's settings (live-kb).
  # The apps, agents, Ollama and the models come later, when the user picks
  # them in the AI app.
  systemd-coredump gdb python3-yaml
  # QEMU (run-qemu.sh): the clipboard shared with the host's window
  # (spice-vdagent, on Xwayland: Mutter bridges its clipboard to Wayland's)
  # and the host's shared folder (9p, shown to the user through bindfs)
  spice-vdagent bindfs
)
if ((HARDWARE)); then
  # Real computers: the generic kernel and all of linux-firmware (a
  # metapackage of every vendor's), Intel's sound DSP firmware and ALSA's
  # device profiles, Wi-Fi (wpa_supplicant, the regulatory database), the
  # Vulkan drivers, and on x86 the CPUs' microcode.
  packages+=(linux-image-generic linux-firmware firmware-sof-signed alsa-ucm-conf
             wpasupplicant wireless-regdb mesa-vulkan-drivers)
  if [[ $ARCH == amd64 ]]; then
    packages+=(intel-microcode amd64-microcode)
  fi
else
  # QEMU: the "virtual" kernel, pruned below to what a VM needs
  packages+=(linux-image-virtual)
fi
in_chroot apt-get install -y "${packages[@]}" "${DESKTOP_PACKAGES[@]}"
if in_chroot dpkg -s modemmanager >/dev/null 2>&1; then
  echo "modemmanager got installed" >&2; exit 1
fi
# Brave's postinst added no repository or key (see /etc/default/brave-origin)
if grep -rlsi "google" "$ROOTFS/etc/apt/sources.list.d/" \
   || ls "$ROOTFS/etc/apt/trusted.gpg.d/" 2>/dev/null | grep -qiE "google|brave"; then
  echo "brave-origin added an apt repository or a trusted key" >&2; exit 1
fi

# The rest of the overlay goes in after the packages whose conffiles it
# replaces, so dpkg never sees a conffile conflict. Its files belong to
# root, whoever owns the checkout (e.g. uid 1001 on a CI runner): with the
# checkout's owner on /, /etc and /usr, sudo refuses to run and systemd's
# sandboxed services (localed) can't write to /etc.
cp -a --no-preserve=ownership "$OVERLAY/." "$ROOTFS/"
# For live-limine-update on an installed arm64 system: Limine boots the raw
# Image inside Ubuntu's EFI zboot vmlinuz, as on the ISO.
install -Dm755 "$(dirname "$0")/unzboot.py" "$ROOTFS/usr/local/lib/live-install/unzboot.py"

desktop_install

echo "==> Configuring the system"
echo "$LIVE_HOSTNAME" > "$ROOTFS/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' \
  "$LIVE_HOSTNAME" > "$ROOTFS/etc/hosts"
echo 'LANG=C.UTF-8' > "$ROOTFS/etc/default/locale"
# No tzdata: without /etc/localtime the system runs on UTC.
rm -f "$ROOTFS/etc/localtime"

install -m 644 "$OVERLAY/etc/skel/.zshrc" "$ROOTFS/etc/skel/.zshrc"
# Brave Origin's first-run settings (usr/local/bin/brave-origin-setup), in
# the skeleton: the live user and the user the welcome app creates get a
# profile that's already set up (no welcome page, no P3A notice, no crash
# report question; Origin's free tier accepted...). Brave merges into it
# when it starts. The default browser is already set (mimeapps.list).
BRAVE_ORIGIN_DIR="$ROOTFS/etc/skel/.config/BraveSoftware/Brave-Origin" \
  sh "$OVERLAY/usr/local/bin/brave-origin-setup"
grep -q '"first_run_finished":true' "$ROOTFS/etc/skel/.config/BraveSoftware/Brave-Origin/Local State" \
  || { echo "Brave Origin's profile in /etc/skel isn't set up" >&2; exit 1; }
# "Change Background…" in the desktop's right-click menu starts
# gnome-background-panel.desktop: usr/local/share/applications has one that
# opens Wallpapers, and comes first in XDG_DATA_DIRS. It has to override
# Settings' own, which must exist.
[[ -f "$ROOTFS/usr/share/applications/gnome-background-panel.desktop" ]] \
  || { echo "Settings' gnome-background-panel.desktop is gone: the right-click override has nothing to replace" >&2; exit 1; }
in_chroot useradd -m -s /usr/bin/zsh -G sudo,video,render,input "$LIVE_USER"
echo "$LIVE_USER:$LIVE_PASSWORD" | in_chroot chpasswd

in_chroot systemctl enable systemd-resolved.service bluetooth.service \
  power-profiles-daemon.service avahi-daemon.service tailscaled.service ufw.service
in_chroot systemctl set-default graphical.target
# Crash notifications for every user (the AI app's live-crash-watch: it only
# speaks up once the user has an AI agent; a user turns it off by masking it).
in_chroot systemctl --global enable live-crash-watch.service
[[ -L "$ROOTFS/etc/systemd/user/graphical-session.target.wants/live-crash-watch.service" ]] \
  || { echo "live-crash-watch.service is not enabled" >&2; exit 1; }
# Cores go to systemd-coredump, where coredumpctl and the agents find them
grep -rqs 'systemd-coredump' "$ROOTFS/usr/lib/sysctl.d/" \
  || { echo "systemd-coredump doesn't handle the cores" >&2; exit 1; }
# The agents' skills (live-agent-link links them into each agent)
for skill in ubuntu-system ubuntu-live-image diagnose-crash knowledge-base; do
  [[ -f "$ROOTFS/usr/local/share/live-ai/skills/$skill/SKILL.md" ]] \
    || { echo "the $skill skill is missing" >&2; exit 1; }
done

# Boot splash: "spinner", with Adwaita Sans instead of the (not installed)
# Cantarell for messages and the disk-unlock prompt.
spinner=/usr/share/plymouth/themes/spinner/spinner.plymouth
sed -i 's/^Font=Cantarell 12/Font=Adwaita Sans 12/; s/^TitleFont=Cantarell Light 30/TitleFont=Adwaita Sans Light 30/' \
  "$ROOTFS$spinner"
in_chroot update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
  default.plymouth "$spinner" 150
in_chroot update-alternatives --set default.plymouth "$spinner"

# Firewall on at boot: incoming traffic denied except SSH and mDNS (avahi);
# Tailscale manages its own interface. ufw only writes its rule files here.
# ufw asks iptables for its version first: iptables-nft can't answer under
# qemu-user (an emulated build, e.g. amd64 on Apple Silicon, has no
# netfilter netlink), iptables-legacy can. Only there: legacy wants the
# host kernel's ip6_tables module, which a CI runner's kernel lacks. The
# rule files are the same either way; nft is back right after.
if ((EMULATED)); then
  in_chroot update-alternatives --quiet --set iptables /usr/sbin/iptables-legacy
  in_chroot update-alternatives --quiet --set ip6tables /usr/sbin/ip6tables-legacy
fi
in_chroot ufw --force default deny incoming >/dev/null
in_chroot ufw --force default allow outgoing >/dev/null
in_chroot ufw allow 22/tcp comment ssh >/dev/null
in_chroot ufw allow 5353/udp comment mdns >/dev/null
if ((EMULATED)); then
  in_chroot update-alternatives --quiet --set iptables /usr/sbin/iptables-nft
  in_chroot update-alternatives --quiet --set ip6tables /usr/sbin/ip6tables-nft
fi
sed -i 's/^ENABLED=.*/ENABLED=yes/' "$ROOTFS/etc/ufw/ufw.conf"

# Rootless podman: subordinate ids for the live user.
grep -q "^$LIVE_USER:" "$ROOTFS/etc/subuid" 2>/dev/null \
  || echo "$LIVE_USER:100000:65536" >> "$ROOTFS/etc/subuid"
grep -q "^$LIVE_USER:" "$ROOTFS/etc/subgid" 2>/dev/null \
  || echo "$LIVE_USER:100000:65536" >> "$ROOTFS/etc/subgid"

# Default apps: Brave Origin for the web, Nautilus for folders.
browser_desktop=brave-origin.desktop
[[ -f "$ROOTFS/usr/share/applications/$browser_desktop" ]] \
  || { echo "$browser_desktop not found" >&2; exit 1; }
mkdir -p "$ROOTFS/etc/xdg"
cat > "$ROOTFS/etc/xdg/mimeapps.list" <<EOF
[Default Applications]
x-scheme-handler/http=$browser_desktop
x-scheme-handler/https=$browser_desktop
text/html=$browser_desktop
inode/directory=org.gnome.Nautilus.desktop
EOF

echo "==> uv $UV_VERSION, pure $PURE_VERSION"
dl="$WORK/downloads"
mkdir -p "$dl"
fetch "$UV_URL" "$UV_SHA256" "$dl/uv.tar.gz"
tar xzf "$dl/uv.tar.gz" -C "$ROOTFS/usr/local/bin" --strip-components=1 --no-same-owner
chmod 755 "$ROOTFS/usr/local/bin/uv" "$ROOTFS/usr/local/bin/uvx"
check_runs "uv $UV_VERSION" uv --version
# pure: its two functions go on zsh's fpath, the prompt is enabled for every
# user in /etc/zsh/zshrc.
fetch "$PURE_URL" "$PURE_SHA256" "$dl/pure.tar.gz"
rm -rf "$dl/pure" && mkdir -p "$dl/pure"
tar xzf "$dl/pure.tar.gz" -C "$dl/pure" --strip-components=1
install -Dm644 "$dl/pure/pure.zsh" "$ROOTFS/usr/local/share/zsh/pure/prompt_pure_setup"
install -Dm644 "$dl/pure/async.zsh" "$ROOTFS/usr/local/share/zsh/pure/async"
install -Dm644 "$dl/pure/license" "$ROOTFS/usr/local/share/doc/pure/copyright"
cat >> "$ROOTFS/etc/zsh/zshrc" <<'EOF'

# Live image: the pure prompt (https://github.com/sindresorhus/pure).
fpath+=(/usr/local/share/zsh/pure)
autoload -U promptinit && promptinit
prompt pure
EOF
in_chroot runuser -u "$LIVE_USER" -- zsh -i -c 'prompt -c' | grep -q pure \
  || { echo "pure prompt is not active in zsh" >&2; exit 1; }

echo "==> Nerd Fonts $NERD_FONTS_VERSION: Hack, JetBrains Mono"
# nerd_font TARBALL DIR DOC LICENSE FAMILY FILES...: the given fonts of a
# Nerd Fonts release into /usr/share/fonts/truetype/DIR, and its LICENSE
# file as /usr/share/doc/DOC/copyright.
nerd_font() {
  local tarball=$1 dir="$ROOTFS/usr/share/fonts/truetype/$2" doc=$3 license=$4 family=$5
  shift 5
  rm -rf "$dir" && mkdir -p "$dir"
  tar xJf "$tarball" -C "$dir" --no-same-owner --wildcards "$@"
  chmod 644 "$dir"/*.ttf
  tar xJf "$tarball" -O "$license" | install -Dm644 /dev/stdin "$ROOTFS/usr/share/doc/$doc/copyright"
  nerd_families+=("$family")
}
nerd_families=()
# Only the Mono variants (terminal fonts): the proportional ones would add
# ~20 MB each. Hack for prompts and eza; JetBrains Mono is Ghostty's font
# (see /etc/skel/.config/ghostty), in the four styles a terminal uses
# (all its weights would be ~39 MB).
fetch "$HACK_NERD_URL" "$HACK_NERD_SHA256" "$dl/hack-nerd.tar.xz"
nerd_font "$dl/hack-nerd.tar.xz" hack-nerd-font fonts-hack-nerd LICENSE.md \
  'Hack Nerd Font Mono' 'HackNerdFontMono-*.ttf'
fetch "$JETBRAINS_NERD_URL" "$JETBRAINS_NERD_SHA256" "$dl/jetbrains-nerd.tar.xz"
nerd_font "$dl/jetbrains-nerd.tar.xz" jetbrains-mono-nerd-font fonts-jetbrains-mono-nerd OFL.txt \
  'JetBrainsMono Nerd Font Mono' JetBrainsMonoNerdFontMono-{Regular,Bold,Italic,BoldItalic}.ttf
in_chroot fc-cache -f
for family in "${nerd_families[@]}"; do
  in_chroot fc-list : family | tr ',' '\n' | grep -qx "$family" \
    || { echo "$family is not installed" >&2; exit 1; }
done
# Ghostty's settings for every user (JetBrains Mono Nerd Font, Catppuccin Mocha).
check_runs "Ghostty's config (/etc/skel/.config/ghostty/config)" \
  runuser -u "$LIVE_USER" -- env HOME="/home/$LIVE_USER" ghostty +validate-config

echo "==> apfs-fuse"
# Read-only by design (upstream's choice). /usr/sbin/mount.apfs (overlay)
# lets mount(8), and so udisks2 and Nautilus, mount APFS partitions with it.
install -m 755 "$APFS_FUSE_OUT/apfs-fuse" "$APFS_FUSE_OUT/apfsutil" "$ROOTFS/usr/local/bin/"
install -Dm644 "$APFS_FUSE_OUT/LICENSE" "$ROOTFS/usr/local/share/doc/apfs-fuse/copyright"

echo "==> icloud-linux"
# iCloud Drive in ~/iCloud (FUSE), for the Backup app's iCloud backups. Each
# user sets it up (icloudctl init, through the app): a systemd user service.
install -m 755 "$ICLOUD_LINUX_OUT"/{icloudctl,icloudd,icloud-status} "$ROOTFS/usr/local/bin/"
install -Dm644 "$ICLOUD_LINUX_OUT/README.md" "$ROOTFS/usr/local/share/doc/icloud-linux/README.md"
install -Dm644 "$APFS_FUSE_OUT/LICENSE.lzfse" "$ROOTFS/usr/local/share/doc/apfs-fuse/copyright.lzfse"
missing=$(in_chroot ldd /usr/local/bin/apfs-fuse | grep 'not found' || true)
[[ -z "$missing" ]] || { echo "apfs-fuse lacks libraries: $missing" >&2; exit 1; }
[[ -x "$ROOTFS/usr/sbin/mount.apfs" ]] || { echo "mount.apfs is missing" >&2; exit 1; }

echo "==> Flathub"
# A system remote, so GNOME Software lists Flathub's apps too.
flathub_key="$WORK/flathub.gpg"
sed -n 's/^GPGKey=//p' "$(dirname "$0")/flathub.flatpakrepo" | base64 -d > "$flathub_key"
check_key "$flathub_key" "$FLATHUB_KEY_FPR"
install -m 644 "$(dirname "$0")/flathub.flatpakrepo" "$ROOTFS/tmp/flathub.flatpakrepo"
in_chroot flatpak remote-add --if-not-exists flathub /tmp/flathub.flatpakrepo
rm -f "$ROOTFS/tmp/flathub.flatpakrepo"
in_chroot flatpak remotes --system --columns=name | grep -qx flathub \
  || { echo "Flathub is not a Flatpak remote" >&2; exit 1; }

echo "==> snapper"
# Config for / (@). Its snapshots live in /.snapshots, i.e. the @snapshots
# subvolume, so they are bootable from the Limine menu (btrfslive.snapshot).
# No timeline in a live system; a snapshot before every apt/dpkg run instead.
cat > "$ROOTFS/etc/snapper/configs/root" <<EOF
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS="$LIVE_USER"
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="5"
TIMELINE_CREATE="no"
TIMELINE_CLEANUP="yes"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
EOF
chmod 640 "$ROOTFS/etc/snapper/configs/root"
# Config for /home (@home): a snapshot every hour, the versions Files shows
# under "Previous Versions" (live-file-versions). They live in
# /home/.snapshots, a subvolume live-home-snapshots.service makes at the
# first boot. SYNC_ACL lets the users in ALLOW_USERS (the live user, then
# the one the welcome app creates) into it; inside, their files keep their
# own permissions. Not in the Cloud Backup: run-backup stays on @home's own
# filesystem (--one-file-system).
cat > "$ROOTFS/etc/snapper/configs/home" <<EOF
SUBVOLUME="/home"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS="$LIVE_USER"
ALLOW_GROUPS=""
SYNC_ACL="yes"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="5"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="24"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
EOF
chmod 640 "$ROOTFS/etc/snapper/configs/home"
if grep -q '^SNAPPER_CONFIGS=' "$ROOTFS/etc/default/snapper"; then
  sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root home"/' "$ROOTFS/etc/default/snapper"
else
  echo 'SNAPPER_CONFIGS="root home"' >> "$ROOTFS/etc/default/snapper"
fi
# The hourly snapshots (only "home" has a timeline) and the cleanup
for unit in snapper-timeline.timer snapper-cleanup.timer; do
  [[ -f "$ROOTFS/usr/lib/systemd/system/$unit" ]] || { echo "$unit is missing" >&2; exit 1; }
done
in_chroot systemctl enable snapper-timeline.timer snapper-cleanup.timer live-home-snapshots.service
cat > "$ROOTFS/etc/apt/apt.conf.d/80-snapper" <<'EOF'
// Snapshot / before apt/dpkg changes packages (bootable from the Limine menu).
DPkg::Pre-Invoke { "if [ -x /usr/bin/snapper ] && [ -e /etc/snapper/configs/root ] && [ -d /.snapshots ]; then snapper --no-dbus -c root create -c number -d 'before apt' || true; fi"; };
EOF

echo "==> Wallpaper"
# One of Ubuntu's stock wallpapers (ubuntu-wallpapers, which gnome-shell
# depends on), picked at random at every build. Its dark variant (or the
# picture itself) is also Limine's background ($WORK/limine-wallpaper.*).
rm -f "$WORK"/limine-wallpaper.*
read -r WALLPAPER WALLPAPER_DARK < <(python3 "$(dirname "$0")/pick-wallpaper.py" "$ROOTFS")
[[ -f "$ROOTFS$WALLPAPER" && -f "$ROOTFS$WALLPAPER_DARK" ]] \
  || { echo "no wallpaper picked" >&2; exit 1; }
cp "$ROOTFS$WALLPAPER_DARK" "$WORK/limine-wallpaper.${WALLPAPER_DARK##*.}"

# GTK 4 / libadwaita apps and GNOME: dark style and GNOME's blue accent.
cat > "$ROOTFS/usr/share/glib-2.0/schemas/90_live-adwaita-dark.gschema.override" <<EOF
[org.gnome.desktop.interface]
color-scheme='prefer-dark'
accent-color='blue'
font-name='Adwaita Sans 11'
EOF

desktop_configure
in_chroot glib-compile-schemas /usr/share/glib-2.0/schemas
[[ $(in_chroot env GSETTINGS_BACKEND=memory gsettings get org.gnome.desktop.interface monospace-font-name) \
   == "'JetBrainsMono Nerd Font Mono 11'" ]] \
  || { echo "GNOME's monospace font is not JetBrains Mono Nerd Font" >&2; exit 1; }
[[ $(in_chroot env GSETTINGS_BACKEND=memory gsettings get org.gnome.nautilus.icon-view default-zoom-level) \
   == "'small-plus'" ]] \
  || { echo "Files' icon size is not small-plus" >&2; exit 1; }

# The image's own packages: Cloud Backup's list of the user's apps
# (apps.py) is what apt-mark shows on top of these.
in_chroot apt-mark showmanual > "$ROOTFS/usr/local/share/live-backup/image-packages"
[[ -s "$ROOTFS/usr/local/share/live-backup/image-packages" ]] \
  || { echo "no list of the image's packages" >&2; exit 1; }

echo "==> Slimming down"
kver=$(ls "$ROOTFS/usr/lib/modules")
if ((!HARDWARE)); then
  # Kernel modules: keep filesystems, networking, crypto and the drivers a VM
  # (QEMU virt, virtio) or a plain USB/NVMe/SCSI setup needs. GPU drivers
  # other than virtio-gpu, wireless/ethernet NICs, sound cards other than
  # virtio-sound, media, etc. go.
  keep_modules='^(fs|crypto|lib|arch|block|kernel|mm|virt|security|net/(?!wireless/|mac80211/)[^ ]*|drivers/(virtio|block|cdrom|char|input|hid|tty|rtc|nvme|bluetooth|firmware|acpi|pci|dma|iommu|platform|base|clk|video|md)/|drivers/net/[^/]+\.ko|drivers/gpu/drm/([^/]+\.ko|virtio/|display/|tiny/|ttm/|clients/)|drivers/scsi/[^/]+\.ko|drivers/usb/(core|host|storage|common|class)/|sound/(core|virtio)/)'
  (cd "$ROOTFS/usr/lib/modules/$kver/kernel" && find . -name '*.ko*' -printf '%P\n' \
    | grep -vP "$keep_modules" | xargs -r rm -f)
  find "$ROOTFS/usr/lib/modules/$kver/kernel" -type d -empty -delete
  # Firmware for real hardware: nothing to load in a VM.
  rm -rf "$ROOTFS/usr/lib/firmware/$kver"
  in_chroot depmod -a "$kver"
fi
for m in btrfs isofs loop virtio_gpu virtio_net virtio_scsi virtio_blk sr_mod \
         usbhid hid_generic xhci_pci btusb tun veth bridge overlay nf_tables \
         virtio_snd 9p 9pnet_virtio; do
  in_chroot modinfo -k "$kver" "$m" >/dev/null 2>&1 \
    || { echo "module $m was pruned" >&2; exit 1; }
done
# Extra glibc charset converters (CJK and legacy encodings); UTF-8 and the
# common ones are built into glibc.
in_chroot dpkg -L libc-gconv-modules-extra | while read -r f; do
  if [[ -f "$ROOTFS$f" ]]; then rm -f "$ROOTFS$f"; fi
done
# What debootstrap unpacked before the dpkg excludes were in place.
find "$ROOTFS/usr/share/doc" -type f ! -name copyright -delete
find "$ROOTFS/usr/share/doc" -type l -delete
rm -rf "$ROOTFS"/usr/share/{man,info,lintian,linda}/* "$ROOTFS/usr/share/qt6/translations"
# What debootstrap unpacked before the excludes: the image's languages stay
find "$ROOTFS/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name locale.alias \
  ! -name it ! -name es ! -name fr ! -name de ! -name pt ! -name pt_BR -exec rm -rf {} +
find "$ROOTFS/usr" -name __pycache__ -type d -prune -exec rm -rf {} +

# Nothing outside /home may belong to a regular user (see the overlay copy).
foreign=$(find "$ROOTFS" -xdev -path "$ROOTFS/home" -prune -o \
  -uid +999 ! -uid 65534 -print -quit)
[[ -z "$foreign" ]] || { echo "${foreign#$ROOTFS} belongs to uid $(stat -c %u "$foreign")" >&2; exit 1; }

echo "==> Building the initramfs"
in_chroot update-initramfs -c -k all
initrd="$(ls "$ROOTFS"/boot/initrd.img-* | head -1 | sed "s|^$ROOTFS||")"
initrd_files=$(in_chroot lsinitramfs "$initrd")
for f in scripts/btrfslive "(usr/)?bin/busybox" usr/share/plymouth/themes/spinner/spinner.plymouth; do
  grep -qxE "$f" <<<"$initrd_files" || { echo "$f missing from the initramfs" >&2; exit 1; }
done

echo "==> Cleaning up"
in_chroot apt-get clean
rm -f "$ROOTFS/usr/sbin/policy-rc.d" "$ROOTFS/etc/resolv.conf.build"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
rm -f "$ROOTFS"/etc/ssh/ssh_host_*
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/dbus/machine-id"
rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/var/cache/apt/*.bin \
  "$ROOTFS"/var/cache/debconf/*-old "$ROOTFS"/var/lib/dpkg/*-old \
  "$ROOTFS"/var/log/*.log "$ROOTFS"/tmp/*

# Desktop part of build-rootfs.sh (sourced): a minimal GNOME 51 with GDM, on
# NetworkManager, set up like Ubuntu's desktop:
#   - ghostty as the terminal ("Open in Ghostty" in Nautilus), with Ptyxis
#     to fall back on, GNOME Software (with Flatpak), Disks, Resources,
#     Extensions, Calculator, Papers (PDF), Fonts, Text Editor
#   - Yaru icons, their variant following the accent color (yaru-accent-sync)
#   - Dash to Dock as Ubuntu's dash (a panel on the left), Kiwi Menu with
#     the Ubuntu logo, Caffeine, Vitals and Rounded Corners
#   - the live user logs in automatically and gets the welcome app
#     (live-welcome), which creates the real user and logs out to GDM
#   - English plus a few languages the welcome app offers; the live session
#     starts in the host's language when it's one of them (live-locale)
# Ubuntu 26.04 ships GNOME 50: GNOME 51 comes from the local repository
# build-gnome.sh fills ($GNOME_REPO).

: "${GNOME_REPO:?}"
GNOME_VERSION=51

# GNOME Shell extensions, pinned and checked: a release on
# extensions.gnome.org (its version_tag), or a source tarball and the
# extension's directory in it, when GNOME $GNOME_VERSION support isn't
# released yet. "force" declares GNOME $GNOME_VERSION for an extension that
# doesn't yet but works with it (tested on GNOME 51.0).
EXTENSIONS=(
  # uuid|version_tag or tarball URL|sha256|directory in the tarball|force
  "dash-to-dock@micxgx.gmail.com|75334|eb7647c03cad6dd1ac608da75ffdd2a2b9f8356b65bb468dc523d7ed3d26e5fc||"
  "kiwimenu@kemma|74796|9d1ee3f9fc0280301e6e044b19d90cf89b3c92c037c3d72670264a3596972e8e||"
  "Vitals@CoreCoding.com|74743|899e5ffe27d1793cf13db069d835c11136cec816717e4e450a56f08bcf976b2f||"
  # master: its last release on extensions.gnome.org stops at GNOME 50
  "caffeine@patapon.info|https://codeload.github.com/eonpatapon/gnome-shell-extension-caffeine/tar.gz/be18b3558a250d672a7108f01a8dcf55c0935bc6|da4f86642847abda6a156ea81d88659c8f628dec82a01c5d84a1128301b83430|caffeine@patapon.info|"
  "Rounded_Corners@lennart-k|70231|f10cf2ee9f621e13f720e987c295a6edd78db8297f560e43cc46d64883a55856||force"
)

# rclone for Cloud Backup: upstream's, not Ubuntu 26.04's 1.60, whose
# `serve restic` hangs reading from SFTP (restores never finish); 1.75 is
# fine. Its own static build, checked by sha256.
RCLONE_VERSION=1.75.1
RCLONE_SHA256=03f2504174034b6d004152ed7369251c9a9ec1f7e0836eda420f5c7a5ec0dff9

# The welcome app's avatars: DiceBear's styles whose drawings are CC0 and
# made of parts one can pick (not the abstract ones), turned into JSON by
# dicebear.py. style|sha256 of @dicebear/<style>-$DICEBEAR_VERSION.tgz
DICEBEAR_VERSION=9.4.2
DICEBEAR_STYLES=(
  "open-peeps|562b2c82245be2b84f46a21665b04ba6604c0549198783ac5b9349f7d5521546"
  "lorelei|de797c458bbcf584991ff3f53665581c9026346787715ba396aa2067ae150535"
  "notionists|e812410b4cbe3da3051b2ad48c9c84253b29eecf284930b81f2eed70760e6581"
  "pixel-art|779d4b46ecb7f2638f00afece0878bc01fbd5294a5bd0db9a0642ec8a807cbb6"
  "thumbs|227e1e202aec9a79c6adc7803dc32996d7a8c2268033fc482b8c540b9c5af994"
)

# Languages the welcome app offers: English plus these (translations come
# from Ubuntu's language packs, in /usr/share/locale-langpack).
LANGPACKS=(it es fr de pt)
LOCALES=(en_US it_IT es_ES fr_FR de_DE pt_BR)

DESKTOP_PACKAGES=(
  # GNOME Shell, the vanilla "GNOME" session and GDM (Wayland only)
  gdm3 gnome-session gnome-shell
  # Settings, the portal (dark style, file chooser)
  gnome-control-center xdg-desktop-portal-gnome
  # apps: terminal (ghostty, the default through xdg-terminal-exec; Ptyxis,
  # Ubuntu's, when ghostty can't start: overlay/usr/local/bin/ghostty),
  # software center (PackageKit/apt), disks, system monitor, extensions
  ghostty xdg-terminal-exec ptyxis gnome-software gnome-disk-utility udisks2
  resources gnome-extensions-app
  # GNOME's basic apps: calculator, PDF viewer (Papers, Evince's successor),
  # fonts, text editor
  gnome-calculator papers gnome-font-viewer gnome-text-editor
  # Nautilus's Python extensions: ghostty ships one ("Open in Ghostty")
  python3-nautilus
  # Cloud Backup (live-backup): restic through rclone (installed below:
  # Google Drive, OneDrive, Dropbox, Nextcloud, Samba, SFTP; ssh-keyscan for
  # SFTP's host keys) or into iCloud Drive (icloud-linux, built by
  # build-icloud-linux.sh, on FUSE), the recovery key in the keyring
  # (libsecret), notifications
  restic openssh-client gir1.2-secret-1 libnotify-bin
  # the providers' icons the Backup app shows (goa-account-google, ...)
  gnome-online-accounts
  # the keyring (org.freedesktop.secrets: the backups' password, apps'
  # secrets), unlocked by the login password through GDM's PAM stack
  gnome-keyring libpam-gnome-keyring
  # Flatpak apps (Flathub) in GNOME Software
  gnome-software-plugin-flatpak
  # Ubuntu's Yaru icons (every accent variant)
  yaru-theme-icon
  # GNOME's network menu and Settings talk to NetworkManager (through
  # netplan: overlay/etc/netplan)
  network-manager
  fonts-adwaita-sans
  locales
  # the welcome app: Python + GTK 4/libadwaita, dconf for the new user's
  # settings, librsvg + cairo for the avatars (SVG -> PNG)
  python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 dconf-cli pkexec gir1.2-rsvg-2.0 python3-gi-cairo
)
for lang in "${LANGPACKS[@]}"; do
  DESKTOP_PACKAGES+=("language-pack-$lang-base" "language-pack-gnome-$lang-base")
done

# The backport repository, bind-mounted into the chroot for the install
# only. Its versions sort above 26.04's, so apt prefers them.
desktop_repos() {
  mkdir -p "$ROOTFS/run/gnome-backports"
  bind "$GNOME_REPO" "$ROOTFS/run/gnome-backports"
  echo "deb [trusted=yes] file:/run/gnome-backports ./" \
    > "$ROOTFS/etc/apt/sources.list.d/gnome-backports.list"
}

desktop_install() {
  local v entry uuid src sha subdir force dir pak keep lang tmp po domain
  for p in gnome-shell mutter-common gdm3 gnome-session-bin gnome-settings-daemon \
           gnome-control-center nautilus xdg-desktop-portal-gnome gnome-extensions-app; do
    v=$(in_chroot dpkg-query -W -f '${Version}' "$p")
    [[ "${v#*:}" == "$GNOME_VERSION".* || "${v#*:}" == "$GNOME_VERSION"~* ]] \
      || { echo "$p is $v, not GNOME $GNOME_VERSION" >&2; exit 1; }
  done
  # The live system only has the Ubuntu archive: nothing points at the
  # (build-time) repository any more.
  rm -f "$ROOTFS/etc/apt/sources.list.d/gnome-backports.list"
  for f in /usr/share/wayland-sessions/gnome.desktop \
           /usr/share/applications/com.mitchellh.ghostty.desktop \
           /usr/share/applications/org.gnome.Ptyxis.desktop \
           /usr/share/applications/org.gnome.Calculator.desktop \
           /usr/share/applications/org.gnome.Papers.desktop \
           /usr/share/applications/org.gnome.font-viewer.desktop \
           /usr/share/applications/org.gnome.TextEditor.desktop \
           /usr/share/nautilus-python/extensions/ghostty.py \
           /usr/share/applications/org.gnome.Software.desktop \
           /usr/share/icons/Yaru-blue-dark/index.theme; do
    [[ -e "$ROOTFS$f" ]] || { echo "$f is missing" >&2; exit 1; }
  done
  # The Backup app keeps its password in the keyring: a secrets service, and
  # GDM unlocking it at login.
  grep -rqs "Name=org.freedesktop.secrets" "$ROOTFS/usr/share/dbus-1/services/" \
    || { echo "no secrets service (gnome-keyring)" >&2; exit 1; }
  grep -q pam_gnome_keyring "$ROOTFS/etc/pam.d/gdm-password" \
    && [[ -n $(find "$ROOTFS/usr/lib" -name pam_gnome_keyring.so -print -quit) ]] \
    || { echo "GDM doesn't unlock the keyring at login" >&2; exit 1; }

  # Ghostty through overlay/usr/local/bin/ghostty (OpenGL in software on
  # virtio-gpu, where virgl lacks the OpenGL 4.3 it needs). The .desktop
  # file, the D-Bus service and the systemd unit all start /usr/bin/ghostty:
  # the package's binary moves to ghostty.real (a dpkg diversion, so
  # upgrades keep it there) and that path becomes the wrapper.
  in_chroot dpkg-divert --local --rename --divert /usr/bin/ghostty.real --add /usr/bin/ghostty
  ln -sf /usr/local/bin/ghostty "$ROOTFS/usr/bin/ghostty"
  [[ -x "$ROOTFS/usr/bin/ghostty.real" && -x "$ROOTFS/usr/local/bin/ghostty" ]] \
    || { echo "the ghostty wrapper isn't in place" >&2; exit 1; }

  # Brave's UI follows LANG: keep its translations for the languages above
  # only (all of them take ~100 MB), and no .pak.info files (build-time
  # resource lists).
  for pak in "$ROOTFS"/opt/brave.com/brave-origin/locales/*; do
    keep=0
    for lang in en "${LANGPACKS[@]}"; do
      case "${pak##*/}" in "$lang.pak"|"$lang"-*.pak) keep=1 ;; esac
    done
    ((keep)) || rm -f "$pak"
  done
  [[ -f "$ROOTFS/opt/brave.com/brave-origin/locales/${LANGPACKS[0]}.pak" ]] \
    || { echo "Brave's translations are missing" >&2; exit 1; }

  echo "==> GNOME Shell extensions"
  mkdir -p "$WORK/downloads"
  for entry in "${EXTENSIONS[@]}"; do
    IFS='|' read -r uuid src sha subdir force <<<"$entry"
    dir="$ROOTFS/usr/share/gnome-shell/extensions/$uuid"
    rm -rf "$dir" && mkdir -p "$dir"
    if [[ "$src" =~ ^[0-9]+$ ]]; then
      fetch "https://extensions.gnome.org/download-extension/$uuid.shell-extension.zip?version_tag=$src" \
        "$sha" "$WORK/downloads/$uuid.zip"
      python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
        "$WORK/downloads/$uuid.zip" "$dir"
    else
      fetch "$src" "$sha" "$WORK/downloads/$uuid.tar.gz"
      tmp=$(mktemp -d)
      tar xzf "$WORK/downloads/$uuid.tar.gz" -C "$tmp" --strip-components=1 --no-same-owner
      cp -r "$tmp/$subdir/." "$dir/"
      rm -rf "$tmp"
    fi
    # Source trees carry their translations as .po (extensions.gnome.org's
    # zips have them compiled): locale/<lang>.po -> locale/<lang>/LC_MESSAGES.
    for po in "$dir"/locale/*.po; do
      [[ -e "$po" ]] || break
      command -v msgfmt >/dev/null || apt-get install -y -qq --no-install-recommends gettext >/dev/null
      domain=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["gettext-domain"])' \
        "$dir/metadata.json")
      lang=$(basename "$po" .po)
      mkdir -p "$dir/locale/$lang/LC_MESSAGES"
      msgfmt -o "$dir/locale/$lang/LC_MESSAGES/$domain.mo" "$po"
      rm -f "$po"
    done
    if [[ "$force" == force ]]; then
      python3 -c '
import json, sys
path, version = sys.argv[1:]
meta = json.load(open(path))
if version not in meta["shell-version"]:
    meta["shell-version"].append(version)
json.dump(meta, open(path, "w"), indent=2)
' "$dir/metadata.json" "$GNOME_VERSION"
    fi
    grep -q "\"$GNOME_VERSION\"" "$dir/metadata.json" \
      || { echo "$uuid does not support GNOME $GNOME_VERSION" >&2; exit 1; }
    # The schema goes into the system directory, compiled with the others,
    # so the gschema override below can set its defaults. The extension's
    # own schemas/ must go: GNOME Shell would look for a gschemas.compiled
    # there (extensions.gnome.org's zips no longer ship one) and fail.
    cp "$dir"/schemas/*.gschema.xml "$ROOTFS/usr/share/glib-2.0/schemas/"
    rm -rf "$dir/schemas"
    chmod -R u=rwX,go=rX "$dir"
  done
}

desktop_configure() {
  in_chroot systemctl enable gdm.service NetworkManager.service
  [[ -L "$ROOTFS/etc/systemd/system/display-manager.service" ]] \
    || { echo "gdm is not the display manager" >&2; exit 1; }
  # NetworkManager has the network: networkd would only wait for it at boot.
  in_chroot systemctl disable systemd-networkd.service systemd-networkd-wait-online.service \
    >/dev/null 2>&1 || true

  # Locales for the languages the welcome app offers. The live session runs
  # in English unless the host asks for one of them: live-locale.service
  # reads the host's language from QEMU (run-qemu.sh) before GDM starts.
  printf '%s.UTF-8 UTF-8\n' "${LOCALES[@]}" > "$ROOTFS/etc/locale.gen"
  in_chroot locale-gen >/dev/null
  echo 'LANG=en_US.UTF-8' > "$ROOTFS/etc/default/locale"
  in_chroot systemctl enable live-locale.service
  # Once the welcome has created the real user, the live one goes
  in_chroot systemctl enable live-retire-user.service
  # The host's folder (run-qemu.sh --shared-folder) in /media, so in Files
  in_chroot systemctl enable live-shared-folder.service

  # The live user logs straight in (no GDM login screen) and gets the welcome
  # app. It creates the real user, turns this off and logs out to GDM.
  sed -i -e '/^\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin='"$LIVE_USER" \
    "$ROOTFS/etc/gdm3/custom.conf"
  grep -q "^AutomaticLogin=$LIVE_USER" "$ROOTFS/etc/gdm3/custom.conf" \
    || { echo "GDM autologin not configured" >&2; exit 1; }
  install -d -m 755 "$ROOTFS/home/$LIVE_USER/.config/autostart"
  # (named after the app id, so the shell shows the app's own icon)
  cp "$ROOTFS/usr/share/applications/org.ubuntu.LiveWelcome.desktop" \
    "$ROOTFS/home/$LIVE_USER/.config/autostart/"
  chown -R "$(stat -c %u:%g "$ROOTFS/home/$LIVE_USER")" "$ROOTFS/home/$LIVE_USER/.config"

  # GDM preselects the session saved in AccountsService: the vanilla GNOME
  # one (there is no Ubuntu session in this image).
  install -d -m 700 "$ROOTFS/var/lib/AccountsService/users"
  printf '[User]\nSession=gnome\nSystemAccount=false\n' \
    > "$ROOTFS/var/lib/AccountsService/users/$LIVE_USER"
  chmod 600 "$ROOTFS/var/lib/AccountsService/users/$LIVE_USER"

  # Keyboard layout: the console and systemd-localed read /etc/default/keyboard;
  # GDM and the session read the GNOME input sources below.
  cat > "$ROOTFS/etc/default/keyboard" <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$XKB_LAYOUT"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

  # Defaults for GDM and every user.
  cat > "$ROOTFS/usr/share/glib-2.0/schemas/91_live-gnome.gschema.override" <<EOF
[org.gnome.desktop.input-sources]
sources=[('xkb', '$XKB_LAYOUT')]

[org.gnome.desktop.background]
picture-uri='file://$WALLPAPER'
picture-uri-dark='file://$WALLPAPER_DARK'

[org.gnome.desktop.screensaver]
picture-uri='file://$WALLPAPER'

# Yaru icons; yaru-accent-sync keeps the variant in step with the accent
# color and the style (blue + dark are the defaults). The monospace font
# (GNOME Tweaks' "Monospace Text") is Ghostty's, from build-rootfs.sh.
[org.gnome.desktop.interface]
icon-theme='Yaru-blue-dark'
monospace-font-name='JetBrainsMono Nerd Font Mono 11'

[org.gnome.shell]
enabled-extensions=['dash-to-dock@micxgx.gmail.com', 'kiwimenu@kemma', 'caffeine@patapon.info', 'Vitals@CoreCoding.com', 'Rounded_Corners@lennart-k', 'cloud-backup@ubuntu-live']
favorite-apps=['org.gnome.Nautilus.desktop', '$browser_desktop', 'com.mitchellh.ghostty.desktop', 'org.gnome.Software.desktop']
welcome-dialog-last-shown-version='999'

# Ubuntu's dash: a full-height panel on the left, "Show Apps" at the bottom,
# no overview at login.
[org.gnome.shell.extensions.dash-to-dock]
dock-position='LEFT'
dock-fixed=true
extend-height=true
height-fraction=1.0
dash-max-icon-size=48
show-apps-at-top=false
show-trash=true
show-mounts=true
custom-theme-shrink=true
transparency-mode='FIXED'
background-opacity=0.8
running-indicator-style='DOTS'
click-action='focus-minimize-or-previews'
disable-overview-on-startup=true

# Kiwi Menu with the Ubuntu logo (icon 8 in its src/icons.json).
[org.gnome.shell.extensions.kiwimenu]
icon=8

# Caffeine: on from login (no screen blanking or automatic suspend).
[org.gnome.shell.extensions.caffeine]
cli-toggle=false
indicator-position-max=2
user-enabled=true

[org.gnome.shell.extensions.lennart-k.rounded_corners]
corner-radius=6

# Vitals: the average temperature in the top bar, memory, network speed in
# bits.
[org.gnome.shell.extensions.vitals]
alphabetize=false
battery-colors=@as []
fan-colors=['2500 0.8784313797950745 0.10588235408067703 0.1411764770746231 sensor:_fan_asus_cpu_fan_']
fixed-widths=false
gpu-colors=@as []
hot-sensors=['__temperature_avg__']
icon-style=1
memory-colors=@as []
network-public-ip-show-flag=false
network-speed-unit=2
processor-colors=@as []
show-memory=true
use-higher-precision=true
EOF

  # Ctrl+Alt+T opens ghostty too (GNOME's own binding runs the
  # xdg-terminal-exec default, see overlay/etc/xdg/xdg-terminals.list).
  [[ -x "$ROOTFS/usr/bin/xdg-terminal-exec" ]] \
    || { echo "xdg-terminal-exec is missing" >&2; exit 1; }

  # live-welcome's state: "done" once the real user exists (the setup
  # helper then refuses to run again).
  install -d -m 755 "$ROOTFS/var/lib/live-welcome"

  # Cloud Backup's top bar indicator (overlay/usr/share/gnome-shell/extensions):
  # GNOME $GNOME_VERSION must be among the versions it declares.
  grep -q "\"$GNOME_VERSION\"" \
    "$ROOTFS/usr/share/gnome-shell/extensions/cloud-backup@ubuntu-live/metadata.json" \
    || { echo "the Cloud Backup extension doesn't declare GNOME $GNOME_VERSION" >&2; exit 1; }

  # The avatar styles live-welcome composes (offline: no network needed).
  local style packages=()
  tmp=$(mktemp -d)
  for entry in "${DICEBEAR_STYLES[@]}"; do
    IFS='|' read -r style sha <<<"$entry"
    fetch "https://registry.npmjs.org/@dicebear/$style/-/$style-$DICEBEAR_VERSION.tgz" "$sha" \
      "$WORK/downloads/dicebear-$style.tgz"
    mkdir "$tmp/$style"
    tar xzf "$WORK/downloads/dicebear-$style.tgz" -C "$tmp/$style" --no-same-owner
    install -Dm644 "$tmp/$style/package/LICENSE" \
      "$ROOTFS/usr/local/share/doc/dicebear-$style/copyright"
    packages+=("$tmp/$style/package")
  done
  install -d -m 755 "$ROOTFS/usr/local/share/live-welcome"
  python3 "$(dirname "$0")/dicebear.py" "$ROOTFS/usr/local/share/live-welcome/dicebear.json" \
    "${packages[@]}"
  chmod 644 "$ROOTFS/usr/local/share/live-welcome/dicebear.json"
  rm -rf "$tmp"

  # rclone (see RCLONE_VERSION)
  fetch "https://downloads.rclone.org/v$RCLONE_VERSION/rclone-v$RCLONE_VERSION-linux-arm64.zip" \
    "$RCLONE_SHA256" "$WORK/downloads/rclone.zip"
  python3 - "$WORK/downloads/rclone.zip" "$ROOTFS/usr/local/bin/rclone" <<'PY'
import shutil, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    name = next(n for n in z.namelist() if n.endswith("/rclone"))
    with z.open(name) as src, open(sys.argv[2], "wb") as dst:
        shutil.copyfileobj(src, dst)
PY
  chmod 755 "$ROOTFS/usr/local/bin/rclone"
  in_chroot rclone version | grep -q "^rclone v$RCLONE_VERSION\$" \
    || { echo "rclone $RCLONE_VERSION isn't working" >&2; exit 1; }

  # The Backup app's own OAuth clients (build.sh --oauth-clients), for
  # Google Drive, OneDrive and Dropbox instead of rclone's shared ones. A
  # desktop app's client secret isn't a secret (it ships with the app).
  if [[ -n "${OAUTH_CLIENTS:-}" ]]; then
    install -d -m 755 "$ROOTFS/etc/live-backup"
    printf '%s' "$OAUTH_CLIENTS" | python3 -c '
import json, sys
clients = json.load(sys.stdin)
assert isinstance(clients, dict) and clients, "not a JSON object"
for name, client in clients.items():
    assert name in ("drive", "onedrive", "dropbox"), f"unknown provider {name}"
    assert client.get("client_id"), f"{name}: no client_id"
json.dump(clients, sys.stdout, indent=2)
' > "$ROOTFS/etc/live-backup/oauth-clients.json" \
      || { rm -f "$ROOTFS/etc/live-backup/oauth-clients.json"
           echo "--oauth-clients: not a valid clients file" >&2; exit 1; }
    chmod 644 "$ROOTFS/etc/live-backup/oauth-clients.json"
    echo "==> Backup: own OAuth clients for $(python3 -c 'import json,sys; print(", ".join(json.load(open(sys.argv[1]))))' "$ROOTFS/etc/live-backup/oauth-clients.json")"
  fi
}

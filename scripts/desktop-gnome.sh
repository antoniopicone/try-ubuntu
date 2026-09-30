# Desktop part of build-rootfs.sh (sourced): a minimal GNOME 51 with GDM, on
# NetworkManager, set up like Ubuntu's desktop:
#   - ghostty as the terminal, GNOME Software, Disks, Resources, Extensions
#   - Yaru icons, their variant following the accent color (yaru-accent-sync)
#   - Dash to Dock as Ubuntu's dash (a panel on the left) and Kiwi Menu with
#     the Ubuntu logo, both from extensions.gnome.org
#   - the live user logs in automatically and gets the welcome app
#     (live-welcome), which creates the real user and logs out to GDM
#   - English plus a few languages the welcome app offers; the live session
#     starts in the host's language when it's one of them (live-locale)
# Ubuntu 26.04 ships GNOME 50: GNOME 51 comes from the local repository
# build-gnome.sh fills ($GNOME_REPO).

: "${GNOME_REPO:?}"
GNOME_VERSION=51

# GNOME Shell extensions from extensions.gnome.org, pinned to the release
# for GNOME 51 (version_tag) and checked.
EXTENSIONS=(
  # uuid|version_tag|sha256
  "dash-to-dock@micxgx.gmail.com|75334|eb7647c03cad6dd1ac608da75ffdd2a2b9f8356b65bb468dc523d7ed3d26e5fc"
  "kiwimenu@kemma|74796|9d1ee3f9fc0280301e6e044b19d90cf89b3c92c037c3d72670264a3596972e8e"
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
  # apps: terminal (ghostty, the default through xdg-terminal-exec),
  # software center (PackageKit/apt), disks, system monitor, extensions
  ghostty xdg-terminal-exec gnome-software gnome-disk-utility udisks2
  resources gnome-extensions-app
  # Ubuntu's Yaru icons (every accent variant)
  yaru-theme-icon
  # GNOME's network menu and Settings talk to NetworkManager (through
  # netplan: overlay/etc/netplan)
  network-manager
  fonts-adwaita-sans
  locales
  # the welcome app: Python + GTK 4/libadwaita, dconf for the new user's
  # settings
  python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 dconf-cli pkexec
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
  local v entry uuid tag sha dir pak keep lang
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
           /usr/share/applications/org.gnome.Software.desktop \
           /usr/share/icons/Yaru-blue-dark/index.theme; do
    [[ -e "$ROOTFS$f" ]] || { echo "$f is missing" >&2; exit 1; }
  done

  # Chromium's UI follows LANG: keep its translations for the languages
  # above only (chromium-l10n has ~120 MB of them), and no .pak.info files
  # (build-time resource lists).
  for pak in "$ROOTFS"/usr/lib/chromium/locales/*; do
    keep=0
    for lang in en "${LANGPACKS[@]}"; do
      case "${pak##*/}" in "$lang.pak"|"$lang"-*.pak) keep=1 ;; esac
    done
    ((keep)) || rm -f "$pak"
  done
  [[ -f "$ROOTFS/usr/lib/chromium/locales/${LANGPACKS[0]}.pak" ]] \
    || { echo "Chromium's translations are missing" >&2; exit 1; }

  echo "==> GNOME Shell extensions"
  mkdir -p "$WORK/downloads"
  for entry in "${EXTENSIONS[@]}"; do
    IFS='|' read -r uuid tag sha <<<"$entry"
    fetch "https://extensions.gnome.org/download-extension/$uuid.shell-extension.zip?version_tag=$tag" \
      "$sha" "$WORK/downloads/$uuid.zip"
    dir="$ROOTFS/usr/share/gnome-shell/extensions/$uuid"
    rm -rf "$dir" && mkdir -p "$dir"
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
      "$WORK/downloads/$uuid.zip" "$dir"
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
# color and the style (blue + dark are the defaults).
[org.gnome.desktop.interface]
icon-theme='Yaru-blue-dark'

[org.gnome.shell]
enabled-extensions=['dash-to-dock@micxgx.gmail.com', 'kiwimenu@kemma']
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
EOF

  # Ctrl+Alt+T opens ghostty too (GNOME's own binding runs the
  # xdg-terminal-exec default, see overlay/etc/xdg/xdg-terminals.list).
  [[ -x "$ROOTFS/usr/bin/xdg-terminal-exec" ]] \
    || { echo "xdg-terminal-exec is missing" >&2; exit 1; }

  # live-welcome's state: "done" once the real user exists (the setup
  # helper then refuses to run again).
  install -d -m 755 "$ROOTFS/var/lib/live-welcome"
}

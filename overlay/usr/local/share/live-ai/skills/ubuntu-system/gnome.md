# GNOME 50: settings, shortcuts, extensions, monitors

The session is GNOME's own ("GNOME", on Wayland), not Ubuntu's: no ubuntu-dock, no
Ubuntu session defaults. The image sets its defaults for GDM and every user with gschema
overrides (`/usr/share/glib-2.0/schemas/90_live-*.gschema.override` and `91_live-*`):
read them to see what a "default" is here.

## First: are you in the session?

gsettings has to reach the user's graphical session. Without `DBUS_SESSION_BUS_ADDRESS`
(over SSH, from a TTY) it falls back to the "memory" backend: the command seems to work
and **saves nothing**.

```bash
echo "$XDG_SESSION_TYPE $DBUS_SESSION_BUS_ADDRESS"
gsettings get org.gnome.desktop.interface color-scheme 2>&1 | grep -i memory && echo "NOT in the session"
```

`dbus-run-session` is no way around it: it writes the database, but the running session
never hears of the change.

## gsettings: find, read, change

```bash
gsettings list-schemas | grep -i <word>      # which schema?
gsettings list-recursively <schema>          # every key, with its value
gsettings describe <schema> <key>            # what it does
gsettings range <schema> <key>               # allowed values
gsettings get <schema> <key>                 # read (log the old value)
gsettings set <schema> <key> <value>         # change
gsettings reset <schema> <key>               # back to the default (ask first)
```

- Strings are GVariant-quoted: `"'prefer-dark'"`; arrays `"['a', 'b']"`.
- `reset` goes back to the image's default (its overrides), not GNOME's upstream one.
- A key `gsettings writable` says is `false` is locked by the system: say so, don't work
  around it.

### Common schemas (always check the keys with `list-recursively`)

| What | Schema |
|---|---|
| Style, accent, fonts, clock | `org.gnome.desktop.interface` |
| Touchpad, mouse (the image sets traditional scrolling) | `org.gnome.desktop.peripherals.touchpad`, `...mouse` |
| Keyboard layouts | `org.gnome.desktop.input-sources` |
| Window buttons, workspaces | `org.gnome.desktop.wm.preferences`, `org.gnome.mutter` |
| Window shortcuts | `org.gnome.desktop.wm.keybindings`, `org.gnome.mutter.keybindings` |
| Shell shortcuts | `org.gnome.shell.keybindings` |
| Media and custom shortcuts | `org.gnome.settings-daemon.plugins.media-keys` |
| Night light | `org.gnome.settings-daemon.plugins.color` |
| Power | `org.gnome.settings-daemon.plugins.power` (profiles: `powerprofilesctl`) |
| Enabled extensions, dash favorites | `org.gnome.shell` (`enabled-extensions`, `favorite-apps`) |
| The dock (Dash to Dock, a full-height panel on the left) | `org.gnome.shell.extensions.dash-to-dock` |
| Caffeine (on from login: no blanking, no automatic suspend) | `org.gnome.shell.extensions.caffeine` |
| Vitals, Kiwi Menu, Rounded Corners | `org.gnome.shell.extensions.vitals`, `...kiwimenu`, `...lennart-k.rounded_corners` |

**Icons follow the accent.** `yaru-accent-sync` (autostart) switches the Yaru icon variant
to match `accent-color` and the light/dark style. Change the accent, not `icon-theme`:
setting the icon theme by hand gets undone at the next accent change.

**Screen blanking and suspend.** Caffeine keeps the screen on from login, by the image's
choice. If the user wants blanking or suspend, Caffeine's `user-enabled` is the switch, not
the power settings alone.

## Custom shortcuts

A relocatable schema: each shortcut is a path, and the list of active paths is a key of
its own.

```bash
mk=org.gnome.settings-daemon.plugins.media-keys

# 1. Is the combination taken? Look in every shortcut schema
for s in org.gnome.desktop.wm.keybindings org.gnome.mutter.keybindings \
         org.gnome.mutter.wayland.keybindings org.gnome.shell.keybindings $mk; do
  gsettings list-recursively "$s" | grep -i "<Super>e'" && echo "  ^ in $s"
done

# 2. The current list
gsettings get $mk custom-keybindings

# 3. A new entry on a free path (a customN not in the list)
p=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
gsettings set $mk.custom-keybinding:$p name    'Files'
gsettings set $mk.custom-keybinding:$p command 'nautilus --new-window'
gsettings set $mk.custom-keybinding:$p binding '<Super>e'

# 4. Add the path to the list WITHOUT losing the others
#    (read it, append, write it back: never overwrite it with one element)
```

To free a combination bound elsewhere, set that key to `[]` (after saving its value).
Ctrl+Alt+T opens the default terminal (ghostty, through `xdg-terminal-exec`).

## Extensions

```bash
gnome-extensions list --enabled
gnome-extensions info <uuid>
gnome-extensions enable <uuid> / disable <uuid>
gnome-extensions prefs <uuid>
```

- The image's extensions are system-wide (`/usr/share/gnome-shell/extensions/`) and their
  schemas are compiled with the system's: plain `gsettings` reaches them. Their versions
  are pinned by the image: don't replace them from extensions.gnome.org.
- `cloud-backup@ubuntu-live` is Cloud Backup's top bar indicator: see `ubuntu-live-image`.
- An extension the user installs goes in `~/.local/share/gnome-shell/extensions/`, with
  its schemas in its own folder: `gsettings --schemadir <that>/schemas ...`.
- A **newly installed** extension can't be enabled in the running Wayland session: it
  needs a logout. Say so instead of retrying.
- Errors: `journalctl -b /usr/bin/gnome-shell | grep -i <uuid>`.

## Monitors (`gdctl`, GNOME 48 and later)

```bash
gdctl show --verbose        # monitors, their modes, properties
gdctl set --help            # options change: read them every time
gdctl set --verify ...      # check without applying
gdctl set ...               # apply (until the next change)
gdctl set --persistent ...  # apply and keep
```

`gdctl set` describes the whole layout (every logical monitor), not just the one to
change: start from `gdctl show`. The kept layout is `~/.config/monitors.xml`: copy it
before `--persistent`. In a QEMU window the display is virtio-gpu: its resolution follows
the window.

## Appearance

- Light/dark: `org.gnome.desktop.interface color-scheme` (`'default'` / `'prefer-dark'`;
  the image defaults to dark).
- Accent: `accent-color` (`gsettings range` lists them); the icons follow by themselves.
- Fonts: `font-name` (Adwaita Sans), `monospace-font-name` (JetBrains Mono Nerd Font,
  also Ghostty's), `text-scaling-factor`.
- Wallpaper: `org.gnome.desktop.background picture-uri` / `picture-uri-dark`.
- GTK 4 CSS for apps: `~/.config/gtk-4.0/gtk.css` (apps started afterwards).

## Default apps and autostart

```bash
xdg-settings get default-web-browser          # Brave Origin
xdg-mime query default <type/mime>
xdg-mime default <app>.desktop <type/mime>
```

Autostart: `.desktop` files in `~/.config/autostart/`. To turn off a system one
(`/etc/xdg/autostart/`), copy it to `~/.config/autostart/` with `Hidden=true`; never delete
the system's.

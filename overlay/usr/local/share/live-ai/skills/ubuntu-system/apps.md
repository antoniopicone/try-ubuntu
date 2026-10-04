# Applications: installing, updating, removing

Two channels: **apt** (the Ubuntu archive, plus Brave's and Tailscale's repositories) and
**Flatpak** (Flathub, a system remote; GNOME Software shows both). There is **no snap**
(no snapd in the image). A few tools come with the image itself (`/usr/local/bin`: uv,
rclone, apfs-fuse, icloud-linux, the image's apps): see `ubuntu-live-image`.

## Three things that differ from a stock Ubuntu

- **No recommends.** `/etc/apt/apt.conf.d/90-no-recommends` turns them off for every
  install. A package that works "out of the box" on Ubuntu may lack a helper here: check
  `apt-cache show <pkg> | grep -i recommends` and add what's needed by name.
- **No documentation.** dpkg skips man pages, docs and other languages' translations
  (`/etc/dpkg/dpkg.cfg.d/01-live-excludes`). `man <cmd>` won't help: use `--help` or the
  web.
- **Pinned repositories.** Brave's repository provides only `brave-origin` and
  `brave-keyring` (`/etc/apt/preferences.d/brave-only`); ModemManager can't be installed
  at all (`no-modemmanager`). Don't lift these pins.

## 1. Is it there already?

```bash
command -v <name>
dpkg -l | grep -i <name>
flatpak list --app | grep -i <name>
ls /usr/share/applications /usr/local/share/applications ~/.local/share/applications \
   /var/lib/flatpak/exports/share/applications 2>/dev/null | grep -i <name>
```

## 2. Which channel

| What | Channel | Why |
|---|---|---|
| Command-line tools, libraries, services, drivers | apt | part of the system, upgraded with it |
| Desktop apps the archive has in a recent version | apt | no extra runtime |
| Desktop apps the archive lacks, or has old | Flatpak (Flathub) | sandboxed, current |
| Python tools | `uv tool install <tool>` | the system Python is managed (PEP 668): no `pip install` into it |
| A vendor's own apt repository | only when it's the vendor's **official** way | see below |

```bash
apt-cache policy <package>
flatpak remote-info flathub <app-id>
flatpak search <name>
```

Tell the user the choice, with the versions found and why, then go ahead.

## 3. Installing

The package lists may be missing on a fresh live system (they're refreshed at boot once
the network is up, by `live-software-refresh`): run `apt-get update` first if
`apt-cache policy` knows nothing.

Simulate first and show what would be installed or **removed**:

```bash
apt-get install -s <package> | grep -E '^(Inst|Remv)'
```

Then, with privileges as in `safety.md` (apt takes its own snapshot first):

```bash
pkexec /usr/bin/apt-get install -y <package>
flatpak install -y --user flathub <app-id>   # --user: no privileges needed
```

### Third-party repositories

Only when the project's **official** documentation gives one, in the modern form: the key
in `/etc/apt/keyrings/` (check its fingerprint against the vendor's page), a deb822
`.sources` file in `/etc/apt/sources.list.d/` with `Signed-By:`. Never `apt-key`, never
`curl ... | bash` without showing the script to the user first.

## 4. Afterwards

- Check it starts: `gtk-launch <file.desktop>` or `<command> --version`.
- Flatpak permissions, when the app must see folders or devices:
  `flatpak info --show-permissions <app-id>`; change them with `flatpak override --user ...`
  (and log it).
- Log the install in the change log.
- Cloud Backup lists the user's apps in every backup (the manually installed apt packages
  the image doesn't have, and the Flatpaks) and offers them again after a restore: nothing
  to do.

## 5. Updating

```bash
pkexec /usr/bin/apt-get update
apt-get -s upgrade | grep -E '^(Inst|Remv)'     # a simulation needs no privileges
flatpak update -y
```

An upgrade of the **GNOME packages** replaces the image's rebuilt versions (which carry
local fixes) with 26.04's: tell the user before a full upgrade. A kernel upgrade on an
installed system goes through `live-limine-update`: see `ubuntu-live-image`.

## 6. Removing (always ask first)

```bash
apt-get remove -s <package>                    # simulate: what goes
pkexec /usr/bin/apt-get remove -y <package>    # purge only if the user wants the config gone
flatpak uninstall --user <app-id>              # --delete-data only when asked
```

Don't remove what the image needs to work (snapper, btrfs-progs, restic, rclone's
dependencies, gnome-keyring, the welcome and cloud apps' Python/GTK packages, plymouth,
efibootmgr) without reading `ubuntu-live-image` and telling the user what would stop
working.

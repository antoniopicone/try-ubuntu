---
name: ubuntu-system
description: >
  REQUIRED for end-user configuration of this Ubuntu system (try-ubuntu: Ubuntu 26.04,
  vanilla GNOME 50 on Wayland): GNOME settings (gsettings/dconf), extensions, keyboard
  shortcuts, the dock, monitors, touchpad, appearance, fonts, default apps, autostart,
  installing or removing applications (apt, Flatpak), user and system services, and
  troubleshooting things that "don't work" without a crash. Triggers: configure, set up,
  change, install, uninstall, "doesn't work", shortcut, theme, monitor, touchpad,
  extension, settings; configura, imposta, installa, "non funziona", scorciatoia, tema.
  Not for crashes (diagnose-crash), the image's own machinery such as the live btrfs,
  snapshots, Limine, Cloud Config/Backup (ubuntu-live-image), or the user's files
  (knowledge-base).
---

# Configuring this Ubuntu system

This system comes from the try-ubuntu image: a hand-picked minimal Ubuntu 26.04
(resolute) with a vanilla GNOME 50 session (not Ubuntu's), set up to look like Ubuntu's
desktop. It runs either live (from the ISO, in RAM or on a persistent disk) or installed
on a disk (`/etc/try-ubuntu/installed` exists). This skill is for changing it as its user,
not for developing the image.

Other skills here:
- a crash, a segfault, "why did X close" → `diagnose-crash`
- the live btrfs, snapshots and rollback, Limine, installing on a disk, Cloud Config,
  Cloud Backup, Tailscale, the QEMU integration, the AI app → `ubuntu-live-image` (read it
  BEFORE touching any of these)
- the user's documents, notes and projects → `knowledge-base`

## Guides

Read the one that fits first:

- [`safety.md`](safety.md): snapshots, backups of settings, privileges, what needs the
  user's yes. **Always, before any change.**
- [`gnome.md`](gnome.md): gsettings, shortcuts, extensions, the dock, monitors, appearance
- [`apps.md`](apps.md): installing, updating and removing applications
- [`diagnostics.md`](diagnostics.md): why something doesn't work (no crash)

## Rules

1. **Look it up, don't remember it.** Keys, schemas, options and packages change between
   versions. Check them on this system (`gsettings list-schemas`, `gsettings describe`,
   `<command> --help`, `apt-cache policy`) before using them. If a command or key doesn't
   exist, **stop and say so**: don't invent a plausible alternative and carry on.
2. **Don't write into what packages or the image own.** Reading is fine; writing isn't:
   - `/usr/**` (including `/usr/share/glib-2.0/schemas`, `/usr/share/gnome-shell`,
     `/usr/local/**`, which is the image's own: its apps, scripts and these skills)
   - `/etc/skel/`

   User changes go in `~/.config/`, `~/.local/share/` and the user's dconf database.
   System changes go in `/etc`, in a drop-in (`*.d/`) where the component has them, never
   over a package's file.
3. **Snapshot or back up first, check afterwards.** See [`safety.md`](safety.md). Every
   change goes in the agents' change log.
4. **Ask before what's destructive or hard to undo**: removing packages or data,
   resetting to defaults, disabling services at boot, rolling back, anything about boot,
   disks, the firewall or sign-ins. Show the exact command first.
5. **No passwords in the chat.** Never ask for the user's password and never use
   `sudo -S`. See "Privileges" in [`safety.md`](safety.md).
6. **Be honest about Wayland.** GNOME Shell can't be restarted without logging out. A new
   extension, some environment variables and group changes need a logout or a reboot:
   say so instead of reporting "done".
7. **Live or installed?** On a live system without a persistent disk everything is lost at
   shutdown (`findmnt /` and `ubuntu-live-image` tell which). Say so before long setups.

## Deciding what to do

1. **Is there a setting?** Find it with gsettings (see [`gnome.md`](gnome.md)): it's
   nearly always the right way, the same one Settings uses.
2. **Is it part of the image?** Read `ubuntu-live-image` first.
3. **Is it an application?** Follow [`apps.md`](apps.md): check whether it's there first.
4. **Is it a config file?** Edit it in `~/.config/` after making a copy.
5. **Is it a service?** `systemctl --user` for the user's, `systemctl` (privileged) for the
   system's; change a unit with a drop-in (`systemctl edit`, or
   `/etc/systemd/system/<unit>.d/*.conf`).
6. **Not sure it exists?** Look on the system before offering it.
7. **AI agents, local models, the knowledge base** are set up in the AI app (`live-ai`),
   not by hand.

## Where to start

```bash
. /etc/os-release; echo "$PRETTY_NAME"; gnome-shell --version; uname -r
live-debug                      # a summary that never asks for a password
gsettings list-schemas | grep -i <word>
gsettings list-recursively <schema>
gsettings describe <schema> <key>
ls /usr/local/bin /usr/local/sbin     # the image's own commands (read-only)
```

## Examples

- "Dark style" → `gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'`,
  after reading and logging the old value.
- "Super+E opens Files" → check the combination is free, then a custom shortcut
  ([`gnome.md`](gnome.md)).
- "The second monitor is on the left" → `gdctl show`, `gdctl set --verify ...`, then the
  same without `--verify`.
- "Install Obsidian" → [`apps.md`](apps.md): not in the archive, so Flatpak (Flathub).
- "Bluetooth doesn't work" → [`diagnostics.md`](diagnostics.md), starting from `live-debug`.
- "Files keeps closing" → `diagnose-crash`.
- "Go back to yesterday's system" → `ubuntu-live-image` (snapshots and `live-rollback`).

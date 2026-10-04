# Diagnosis: "something doesn't work" (no crash)

A program that closed suddenly, or a core dump: that's `diagnose-crash`. This guide is for
everything else.

A diagnosis **reads**. Change nothing until you've told the user what you found and what
you propose.

## 1. The overall picture

```bash
live-debug                    # versions, live or installed, failed units, recent errors
live-debug --section errors   # one section (live-debug --list)
```

## 2. Narrow it down in time

Ask or work out **when** it started, then compare:

```bash
journalctl --since "YYYY-MM-DD HH:MM" --until "..." -p warning --no-pager
grep -E ' (install|upgrade|remove) ' /var/log/dpkg.log | tail -30   # recent package changes
snapper -c root list | tail -10                                      # what changed, and when
tail -20 ~/.local/state/live-ai/agent-changes.log 2>/dev/null          # what agents changed
```

A problem that started right after an upgrade or an agent's change is nearly always there.
`snapper -c root status <pre>..<post>` lists the files that changed between two
snapshots.

## 3. Where to look

```bash
# Network (NetworkManager, through netplan; systemd-networkd is off)
nmcli general; nmcli device; resolvectl status; journalctl -b -u NetworkManager --no-pager | tail -50
# Firewall: ufw denies incoming traffic except SSH (22) and mDNS (5353)
pkexec /usr/sbin/ufw status verbose
# Tailscale
tailscale status
# Sound (PipeWire; virtio-sound in a VM)
wpctl status; journalctl --user -b -u wireplumber -u pipewire --no-pager | tail -50
# Bluetooth
bluetoothctl show; journalctl -b -u bluetooth --no-pager | tail -50
# Monitors
gdctl show --verbose
# Graphics: in a VM it's virtio-gpu with llvmpipe (software) or virgl
for c in /sys/class/drm/card?; do echo "$c: $(basename "$(readlink -f $c/device/driver)")"; done
journalctl -b /usr/bin/gnome-shell --no-pager | grep -i -E 'renderer|egl|virgl' | tail
# GNOME Shell and extensions
journalctl -b /usr/bin/gnome-shell --no-pager | tail -80
# Slow boot
systemd-analyze; systemd-analyze blame | head -20
# Disk space (snapshots take space: snapper -c root list, snapper -c home list)
df -h; pkexec /usr/bin/btrfs filesystem usage /
# A Flatpak app
flatpak run --verbose <app-id>; flatpak info --show-permissions <app-id>
```

Things particular to this image:

- **A device that works on a real computer but not in the VM** (Wi-Fi, a sound card, a
  GPU): the QEMU flavour's kernel is cut down to what a VM needs, with no firmware. That's
  by design; the hardware ISO (`build.sh --hardware`) has it all. See `ubuntu-live-image`.
- **Ghostty draws in software** in a VM (virgl lacks OpenGL 4.3), and falls back to Ptyxis
  when it can't start: slowness there isn't a bug to fix.
- **Settings gone after a reboot** on a live system: it was running in RAM (no persistent
  disk). See `ubuntu-live-image`.
- **A cloud folder that's slow or empty** in Files: Cloud Config's rclone mounts fetch on
  open; see `ubuntu-live-image`.

## 4. Report

1. What doesn't work, and since when.
2. What you found, keeping apart what the logs **show** and what you **infer**.
3. The fix you propose, with the exact command and how to undo it.

Then, only after the user's yes, apply it as `safety.md` says.

---
name: ubuntu-live-image
description: >
  REQUIRED before touching what the try-ubuntu image builds in its own way: the live
  btrfs (a read-only seed plus a writable sprout in RAM or on a persistent disk), snapper
  snapshots, booting a snapshot and live-rollback, Limine and live-limine-update,
  installing on a disk, the welcome app, Cloud Config (cloud mounts in Files, Tailscale),
  Cloud Backup (restic, the recovery key), the QEMU integration (shared folder,
  clipboard), the cut-down VM kernel, and the AI app with its tools (live-agent, live-kb,
  crash notifications). Triggers: snapshot, rollback, restore, boot, Limine, persistent
  disk, live session, install on disk, backup, restore, Cloud Config, Google Drive,
  iCloud, Tailscale, shared folder, VM, QEMU, firmware, AI app, Ollama, agent.
---

# The try-ubuntu image's own machinery

This system isn't a stock Ubuntu install: it boots from (or was installed from) a live
ISO that does several things its own way. Read the guide that applies before changing any
of it. The general rules (snapshots, privileges, asking first) are those of
`ubuntu-system`.

- [`storage-boot.md`](storage-boot.md): live or installed, the btrfs seed and sprout,
  snapshots and `live-rollback`, Limine, kernels, the VM kernel and the hardware ISO
- [`cloud.md`](cloud.md): Cloud Config (the clouds in Files, Tailscale) and Cloud Backup
  (restic, the recovery key, restoring)
- [`ai.md`](ai.md): the AI app, the agents, the local model, the knowledge base, crash
  notifications

## What's whose

| Where | What | For an agent |
|---|---|---|
| `/usr/local/bin`, `/usr/local/sbin`, `/usr/local/lib` | the image's apps and helpers (`live-*`, `yaru-accent-sync`, the ghostty wrapper, uv, rclone, apfs-fuse, icloud-linux) | read to understand; never edit |
| `/usr/share/polkit-1/actions/org.ubuntu.*` | rules that let the image's apps run their helpers | don't call those helpers yourself |
| `/etc/systemd/system/live-*`, `/etc/systemd/user/live-*` | the image's units | drop-ins only, and only with a reason |
| `/var/lib/live-welcome` | the welcome app's state (done once) | never touch |
| `~/.config/live-backup` | Cloud Config's accounts and Cloud Backup's settings (secrets inside) | never read out, never copy |
| `~/.config/live-ai`, `~/.local/state/live-ai` | the AI app's settings, the agents' change log | the AI app manages them |

## Three principles

1. **What looks odd is often deliberate.** A cut-down kernel, no recommends, no docs,
   pinned repositories, Caffeine on, Ghostty in software rendering: each is a choice the
   image's README explains. Don't "restore the default" without knowing why it changed.
2. **Live is volatile.** On a live system without a persistent disk, everything (installs,
   settings, snapshots) is gone at shutdown. Check before a long setup, and say so.
3. **Boot, disks and sign-ins only with an explicit yes**, a fresh snapshot, and the way
   back explained to the user first.

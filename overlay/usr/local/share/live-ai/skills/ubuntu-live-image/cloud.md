# Cloud Config and Cloud Backup

Both apps are the image's own (`live-cloud-config`, `live-backup`, with their library in
`/usr/local/lib/live-backup`). Change their state through the apps, not by editing their
files: the user can open them from the app grid.

## Cloud Config: the clouds in Files, Tailscale

- Each connected cloud (Google Drive, OneDrive, Dropbox, Nextcloud) is an rclone remote,
  `acct-<id>`, listed in `~/.config/live-backup/accounts.json`, mounted in the home folder
  (`~/Google Drive`, `~/Nextcloud`…) by a user unit at every login (`live-cloud@.service`).
  iCloud Drive is icloud-linux's own mount, `~/iCloud`.
- **These mounts fetch files when they're opened.** Never walk, search, index, `du` or
  `grep -r` them: it downloads the whole drive. Find what you need by name with `ls` on
  the folder the user points to. The knowledge base refuses them for the same reason.
- "Show the clouds in Files" (in the app) turns every mount off and on.
- **Tailscale**: `tailscale status` to read; joining or leaving a tailnet is the user's
  decision, through the app or `tailscale up/down`.
- Signing in again, disconnecting a cloud: through the app (it knows which one holds the
  backups and refuses to disconnect it).

## Cloud Backup: restic, end-to-end encrypted

- Hourly (`live-backup.timer`, a user timer) backups of the home folder, with restic
  through rclone, into one of the clouds, Samba or SFTP. Excluded: caches, Trash,
  container images, `~/iCloud` (`/usr/local/share/live-backup/excludes`).
- **The recovery key** encrypts everything (restic, and rclone's crypt for the names). It
  lives in the GNOME keyring. **Never read it out, print it, copy it or put it in a file**:
  whoever has it can open the backups. If the user lost it, tell them plainly that without
  it nobody can open the backups.
- The settings are in `~/.config/live-backup` (passwords inside, obscured the rclone way):
  never show them.
- **State**: the top bar indicator (extension `cloud-backup@ubuntu-live`), or
  `systemctl --user status live-backup.service`,
  `journalctl --user -u live-backup.service`, and
  `~/.local/state/live-backup/progress.json` during a backup.
- **Restoring**: in the app (the status page restores the newest backup; at setup it
  offers to when the chosen folder already has backups). It brings back documents and
  settings, and offers to reinstall the user's apps (the apt packages the image doesn't
  have, and the Flatpaks). Don't run `restic restore` by hand.
- **A failing backup** with an iCloud destination usually means Apple wants a new sign-in
  (every few weeks): Cloud Config → iCloud Drive.

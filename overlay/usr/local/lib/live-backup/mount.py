"""mount: the backups' cloud in Files (Nautilus), for the Cloud Backup app.

The destination ("cloud:", see cloud.py) is mounted with rclone in the home
folder (~/Google Drive, ~/Nextcloud, ~/SFTP (anna@server)...) by a systemd
user unit, live-cloud-mount.service, at every login, and gets a place in
Files' sidebar (a GTK bookmark). Files are fetched when opened, and cached
in ~/.cache/rclone (not backed up). The backups' encrypted folder is hidden
from it, so it can't be deleted there by mistake, and the search indexer
(localsearch) is kept out of it, so it doesn't download the whole drive.
iCloud Drive has its own mount already (icloud-linux, ~/iCloud).
"""
import os
import subprocess
import urllib.parse

from gi.repository import Gio

import cloud

UNIT = "live-cloud-mount.service"
ENV = os.path.join(cloud.HOME, ".config/live-backup/mount.env")
BOOKMARKS = os.path.join(cloud.HOME, ".config/gtk-3.0/bookmarks")
INDEXER = "org.freedesktop.Tracker3.Miner.Files"


def name_for(config):
    name = cloud.PROVIDERS[config["provider"]]
    if config["provider"] in ("samba", "sftp") and config.get("identity"):
        name = f"{name} ({config['identity']})"
    return name.replace("/", "-")


def path_for(config):
    return os.path.join(cloud.HOME, name_for(config))


def _systemctl(*args):
    return subprocess.run(["systemctl", "--user", *args], capture_output=True, text=True)


def _bookmark(path):
    return "file://" + urllib.parse.quote(path)


def _set_bookmark(path, name, present):
    lines = open(BOOKMARKS).read().splitlines() if os.path.exists(BOOKMARKS) else []
    lines = [l for l in lines if l.split(" ", 1)[0] != _bookmark(path)]
    if present:
        lines.append(f"{_bookmark(path)} {name}")
    os.makedirs(os.path.dirname(BOOKMARKS), exist_ok=True)
    with open(BOOKMARKS, "w") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))


def _set_indexed(path, indexed):
    """Keep localsearch out of the mount (or let it back in)."""
    source = Gio.SettingsSchemaSource.get_default()
    if source is None or source.lookup(INDEXER, True) is None:
        return
    settings = Gio.Settings.new(INDEXER)
    ignored = [d for d in settings.get_strv("ignored-directories") if d != path]
    if not indexed:
        ignored.append(path)
    settings.set_strv("ignored-directories", ignored)
    Gio.Settings.sync()


def _current():
    """The mount set up now: (path, name), or None."""
    try:
        values = dict(line.split("=", 1) for line in open(ENV).read().splitlines() if "=" in line)
    except OSError:
        return None
    return values.get("MOUNT_DIR"), values.get("MOUNT_NAME")


def set_up(config):
    """Mount the configured destination (after the backups are set up)."""
    remove()
    if config["provider"] == "icloud":
        return None
    path, name = path_for(config), name_for(config)
    os.makedirs(path, exist_ok=True)
    os.makedirs(os.path.dirname(ENV), exist_ok=True)
    with open(ENV, "w") as f:
        # systemd's EnvironmentFile: no quotes needed, spaces are kept
        f.write(f"MOUNT_DIR={path}\nMOUNT_NAME={name}\n"
                f"VAULT_EXCLUDE=/{config['repo'].strip('/')}/**\n")
    _set_indexed(path, False)
    _set_bookmark(path, name, True)
    for args in (("daemon-reload",), ("enable", UNIT), ("restart", UNIT)):
        result = _systemctl(*args)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or f"systemctl {' '.join(args)}")
    return path


def remove():
    """Unmount and forget the destination's mount (the backups stopped, or
    go elsewhere)."""
    current = _current()
    _systemctl("disable", "--now", UNIT)
    if current and current[0]:
        path, name = current
        _set_bookmark(path, name, False)
        _set_indexed(path, True)
        try:
            os.rmdir(path)  # only if empty, i.e. unmounted
        except OSError:
            pass
    try:
        os.remove(ENV)
    except FileNotFoundError:
        pass

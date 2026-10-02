"""mount: the clouds in Files (Nautilus).

Cloud Config's accounts (accounts.py) are each mounted with rclone in the
home folder (~/Google Drive, ~/Nextcloud...) by a systemd user unit,
live-cloud@<id>.service, at every login, and Files lists each in its
sidebar (as it does any mount in the home folder). Cloud Backup's own network destinations (Samba, SFTP:
"cloud:", see cloud.py) are mounted the same way by live-cloud-mount.service
(~/SFTP (anna@server)...). Files are fetched when opened, and cached in
~/.cache/rclone (not backed up). The backups' encrypted folder is hidden
from the mount it is on, so it can't be deleted there by mistake, and the
search indexer (localsearch) is kept out of every mount, so it doesn't
download the whole drive. iCloud Drive has its own mount already
(icloud-linux, ~/iCloud).
"""
import os
import subprocess
import urllib.parse

from gi.repository import Gio

import cloud

UNIT = "live-cloud-mount.service"
ENV = os.path.join(cloud.HOME, ".config/live-backup/mount.env")
ACCOUNT_UNIT = "live-cloud@{}.service"
ACCOUNT_ENVS = os.path.join(cloud.HOME, ".config/live-backup/mounts")
# rclone mount's --exclude for a mount with no backups in it
NO_VAULT = "/.no-backups-here/**"
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
    # No bookmark: Files lists a mount in the home folder on its own (with
    # an eject button); a bookmark would show it twice. One left by an
    # older version goes.
    _set_bookmark(path, name, False)
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


# --- Cloud Config's accounts ---------------------------------------------------------

def account_path(account):
    if account["provider"] == "icloud":
        return cloud.ICLOUD_MOUNT
    return os.path.join(cloud.HOME, account["name"])


def _account_env(account):
    return os.path.join(ACCOUNT_ENVS, f"{account['id']}.env")


def account_mounted(account):
    if account["provider"] == "icloud":
        return os.path.ismount(cloud.ICLOUD_MOUNT)
    return os.path.exists(_account_env(account))


def mount_account(account, vault=None):
    """In Files: the account at ~/<name>, its backups' folder (vault, a path
    in it) hidden. iCloud Drive mounts itself (icloud-linux)."""
    if account["provider"] == "icloud":
        return cloud.ICLOUD_MOUNT
    path, name = account_path(account), account["name"]
    os.makedirs(path, exist_ok=True)
    os.makedirs(ACCOUNT_ENVS, exist_ok=True)
    with open(_account_env(account), "w") as f:
        f.write(f"MOUNT_DIR={path}\nMOUNT_NAME={name}\n"
                f"VAULT_EXCLUDE={'/' + vault.strip('/') + '/**' if vault else NO_VAULT}\n")
    _set_indexed(path, False)
    # No bookmark: Files lists a mount in the home folder on its own (with
    # an eject button); a bookmark would show it twice. One left by an
    # older version goes.
    _set_bookmark(path, name, False)
    unit = ACCOUNT_UNIT.format(account["id"])
    for args in (("daemon-reload",), ("enable", unit), ("restart", unit)):
        result = _systemctl(*args)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or f"systemctl {' '.join(args)}")
    return path


def unmount_account(account):
    if account["provider"] == "icloud":
        subprocess.run(["icloudctl", "stop"], capture_output=True)
        return
    _systemctl("disable", "--now", ACCOUNT_UNIT.format(account["id"]))
    path = account_path(account)
    _set_bookmark(path, account["name"], False)
    _set_indexed(path, True)
    try:
        os.rmdir(path)  # only if empty, i.e. unmounted
    except OSError:
        pass
    try:
        os.remove(_account_env(account))
    except FileNotFoundError:
        pass


def set_vault(account, vault):
    """The backups' folder on the account (None: there's none any more),
    hidden from its mount: remounted if it is mounted."""
    if account["provider"] != "icloud" and account_mounted(account):
        mount_account(account, vault)

"""accounts: the cloud accounts Cloud Config (live-cloud-config) signs in to,
which Files shows and Cloud Backup can keep the backups on.

~/.config/live-backup/accounts.json lists them:
  {"accounts": [{"id", "provider", "identity", "name"}], "show_in_files": true}
Each but iCloud Drive is an rclone remote of its own, "acct-<id>", in the
shared rclone.conf (cloud.py), holding its sign-in (an OAuth token rclone
renews, Nextcloud's app password). iCloud Drive is icloud-linux's: its
session is icloud-linux's, and it is mounted in ~/iCloud by icloud.service.

In Files each account is ~/<name>, an rclone mount (mount.py,
live-cloud@<id>.service) with its place in the sidebar; "name" is the
provider's name ("Google Drive"), with the identity after it when the same
provider is there twice.
"""
import json
import os
import secrets

import cloud

ACCOUNTS = os.path.join(cloud.HOME, ".config/live-backup/accounts.json")
# The clouds Cloud Config offers, in its order (Samba and SFTP are Cloud
# Backup's own destinations: not accounts)
PROVIDERS = ("google", "onedrive", "dropbox", "nextcloud", "icloud")


def _load():
    try:
        data = json.load(open(ACCOUNTS))
    except (OSError, ValueError):
        data = {}
    data.setdefault("accounts", [])
    data.setdefault("show_in_files", True)
    return data


def _save(data):
    os.makedirs(os.path.dirname(ACCOUNTS), exist_ok=True)
    tmp = ACCOUNTS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, ACCOUNTS)


def all_accounts():
    return [a for a in _load()["accounts"] if a.get("provider") in PROVIDERS]


def find(account_id):
    return next((a for a in all_accounts() if a["id"] == account_id), None)


def remote(account):
    """The account's rclone remote; None for iCloud Drive (a mount)."""
    return None if account["provider"] == "icloud" else f"acct-{account['id']}"


def show_in_files():
    return _load()["show_in_files"]


def set_show_in_files(show):
    data = _load()
    data["show_in_files"] = bool(show)
    _save(data)


def _name(provider, identity, taken):
    if provider == "icloud":
        return "iCloud"  # icloud-linux's mount, ~/iCloud
    name = cloud.PROVIDERS[provider]
    if name in taken and identity:
        name = f"{name} ({identity})"
    return name.replace("/", "-")


def add(provider, identity, options=None):
    """A new account: its rclone remote (options), then its entry. The
    caller has checked the sign-in already."""
    data = _load()
    account = {"id": secrets.token_hex(4), "provider": provider, "identity": identity or "",
               "name": _name(provider, identity, {a["name"] for a in data["accounts"]})}
    if options is not None:
        cloud.set_remote(remote(account), options)
    data["accounts"].append(account)
    _save(data)
    return account


def forget(account_id):
    """The account's entry and its remote (the caller unmounts it first)."""
    data = _load()
    account = next((a for a in data["accounts"] if a["id"] == account_id), None)
    if account is None:
        return
    if remote(account):
        cloud.remove_remote(remote(account))
    data["accounts"] = [a for a in data["accounts"] if a["id"] != account_id]
    _save(data)


def backing_up(account_id):
    """Cloud Backup keeps the backups on this account."""
    config = cloud.load_config()
    return bool(config and config.get("account") == account_id)

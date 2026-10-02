"""cloud: what the Cloud Backup app (live-backup) and the backup job
(run-backup) share: the configuration, where the backups go, the recovery
key in the keyring, and restic.

The backups are encrypted twice, end to end, with keys that come from one
recovery key (random, 160 bits, shown to the user once as 8 groups of 4
characters, to keep somewhere safe):
  - restic encrypts the content, the names and the layout of the home
    folder (the repository's password is derived from the key);
  - under it, rclone's crypt encrypts the names of restic's own files and
    folders: the destination holds one folder with a neutral random name,
    and in it only encrypted names. Nothing there says it's a backup,
    restic, Ubuntu, or whose.
The key never goes to a file: it's in the GNOME keyring, and crypt's two
passwords, derived from it, reach rclone through the environment.

Destinations are rclone remotes in ~/.config/live-backup/rclone.conf (only
the user can read it): "cloud:" is the destination, "vault:" the encrypted
folder in it. On a cloud (Google Drive, OneDrive, Dropbox, Nextcloud) it is
an alias of the account Cloud Config signed in to ("acct-<id>:", see
accounts.py); iCloud Drive is an alias of the icloud-linux mount ~/iCloud;
Samba and SFTP are remotes of Cloud Backup's own. While the app sets up a destination they're "setup:" and "setupvault:",
and they replace the others only once the backups are set up, so backing
out halfway leaves the current backups alone.
"""
import configparser
import hashlib
import json
import os
import re
import secrets
import subprocess

import gi

gi.require_version("Secret", "1")
from gi.repository import Secret  # noqa: E402

HOME = os.path.expanduser("~")
CONFIG = os.path.join(HOME, ".config/live-backup/config.json")
STATUS = os.path.join(HOME, ".local/state/live-backup/status.json")
# While a backup runs: its progress, rewritten every second (see run-backup)
PROGRESS = os.path.join(HOME, ".local/state/live-backup/progress.json")
RCLONE_CONFIG = os.path.join(HOME, ".config/live-backup/rclone.conf")
KNOWN_HOSTS = os.path.join(HOME, ".config/live-backup/known_hosts")
EXCLUDES = "/usr/local/share/live-backup/excludes"
ICLOUD_MOUNT = os.path.join(HOME, "iCloud")
PROVIDERS = {"google": "Google Drive", "onedrive": "OneDrive", "dropbox": "Dropbox",
             "nextcloud": "Nextcloud", "icloud": "iCloud Drive", "samba": "Samba",
             "sftp": "SFTP"}
REMOTE, VAULT = "cloud", "vault"
SETUP_REMOTE, SETUP_VAULT = "setup", "setupvault"
SCHEMA = Secret.Schema.new("org.ubuntu.LiveBackup", Secret.SchemaFlags.NONE,
                           {"repository": Secret.SchemaAttributeType.STRING})
# restic's exit codes (0.17+)
RESTIC_NO_REPO, RESTIC_BAD_PASSWORD = 10, 12

# The encrypted folder's neutral name: 20 characters of base32
VAULT_NAME = re.compile(r"^[a-z2-7]{20}$")
# The recovery key: Crockford's base32 (no I, L, O, U), 8 groups of 4
KEY_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
KEY_GROUPS = 8


def _load(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return None


def _save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def load_config():
    return _load(CONFIG)


def save_config(config):
    _save(CONFIG, config)


def load_status():
    return _load(STATUS)


def save_progress(progress):
    """Atomically: the top bar's indicator reads it whenever it changes."""
    os.makedirs(os.path.dirname(PROGRESS), exist_ok=True)
    tmp = PROGRESS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(progress, f)
    os.replace(tmp, PROGRESS)


def clear_progress():
    try:
        os.remove(PROGRESS)
    except FileNotFoundError:
        pass


def save_status(status):
    _save(STATUS, status)


# --- the recovery key -------------------------------------------------------------

def new_key():
    return "-".join("".join(secrets.choice(KEY_ALPHABET) for _ in range(4))
                    for _ in range(KEY_GROUPS))


def _raw(text):
    """As typed: any case, spaces or dashes, O for 0, I or L for 1."""
    return re.sub(r"[\s\-]", "", text.upper()).translate(str.maketrans("OIL", "011"))


def normalize_group(text):
    return _raw(text)


def normalize_key(text):
    """The key as typed, in its canonical form; None if it can't be one."""
    raw = _raw(text)
    if len(raw) != 4 * KEY_GROUPS or any(c not in KEY_ALPHABET for c in raw):
        return None
    return "-".join(raw[i:i + 4] for i in range(0, len(raw), 4))


def key_groups(key):
    return key.split("-")


def _derive(key, purpose):
    return hashlib.sha256(f"live-backup/{purpose}/{key}".encode()).hexdigest()


def restic_password(key):
    return _derive(key, "restic")


def new_vault_name():
    return "".join(secrets.choice("abcdefghijklmnopqrstuvwxyz234567") for _ in range(20))


def store_key(repo, key):
    Secret.password_store_sync(SCHEMA, {"repository": repo}, Secret.COLLECTION_DEFAULT,
                               f"Cloud Backup recovery key ({repo})", key, None)


def lookup_key(repo):
    return Secret.password_lookup_sync(SCHEMA, {"repository": repo}, None)


# --- rclone ------------------------------------------------------------------------

def _private(path):
    """Create the file (and its folder) readable by the user only."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    os.close(os.open(path, os.O_WRONLY | os.O_CREAT, 0o600))
    os.chmod(path, 0o600)


def obscure(secret):
    return subprocess.run(["rclone", "obscure", "-"], input=secret, text=True,
                          capture_output=True, check=True).stdout.strip()


def env(key=None):
    """rclone's environment; with the key, the vaults' crypt passwords too."""
    _private(RCLONE_CONFIG)
    result = dict(os.environ, RCLONE_CONFIG=RCLONE_CONFIG)
    if key:
        first, second = obscure(_derive(key, "crypt")), obscure(_derive(key, "crypt-salt"))
        for vault in (VAULT, SETUP_VAULT):
            result[f"RCLONE_CONFIG_{vault.upper()}_PASSWORD"] = first
            result[f"RCLONE_CONFIG_{vault.upper()}_PASSWORD2"] = second
    return result


def remote_path(path, remote=REMOTE):
    return f"{remote}:{path.strip('/')}"


def _remotes():
    _private(RCLONE_CONFIG)
    config = configparser.RawConfigParser()
    config.read(RCLONE_CONFIG)
    return config


def _write(config):
    with open(RCLONE_CONFIG, "w") as f:
        config.write(f)


def remote_options(remote=REMOTE):
    config = _remotes()
    return dict(config[remote]) if config.has_section(remote) else {}


def set_remote(name, options):
    """A remote of its own (a cloud account of Cloud Config: "acct-<id>")."""
    config = _remotes()
    config[name] = {k: str(v) for k, v in options.items() if v not in (None, "")}
    _write(config)


def remove_remote(name):
    config = _remotes()
    if config.remove_section(name):
        _write(config)


def alias(remote):
    """A remote that is another one under this name: the backups' "cloud:"
    on a Cloud Config account, so that both use one sign-in (rclone writes a
    renewed token back to the account's own section)."""
    return {"type": "alias", "remote": f"{remote}:"}


def set_setup_remote(options):
    """The destination being set up, as the "setup:" remote."""
    config = _remotes()
    config[SETUP_REMOTE] = {k: str(v) for k, v in options.items() if v not in (None, "")}
    _write(config)


def set_setup_vault(path):
    """The encrypted folder at `path` of the destination being set up."""
    config = _remotes()
    config[SETUP_VAULT] = {"type": "crypt", "remote": remote_path(path, SETUP_REMOTE),
                           "filename_encryption": "standard",
                           "directory_name_encryption": "true"}
    _write(config)


def promote_setup_remote():
    """The set-up destination becomes the backups' ("cloud:", "vault:");
    rclone may have renewed its token in the meantime, so it's read back."""
    config = _remotes()
    if config.has_section(SETUP_REMOTE):
        config[REMOTE] = dict(config[SETUP_REMOTE])
        config.remove_section(SETUP_REMOTE)
    if config.has_section(SETUP_VAULT):
        vault = dict(config[SETUP_VAULT])
        vault["remote"] = REMOTE + vault["remote"][len(SETUP_REMOTE):]
        config[VAULT] = vault
        config.remove_section(SETUP_VAULT)
    _write(config)


# --- restic --------------------------------------------------------------------------

def vault_of(remote):
    return SETUP_VAULT if remote == SETUP_REMOTE else VAULT


def repository(config, remote=REMOTE):
    return f"rclone:{vault_of(remote)}:"


def restic_cmd(config, *args, remote=REMOTE):
    return ["restic", *args]


def restic_env(base, config, key, remote=REMOTE):
    """restic's environment: the repository (the vault), its password
    (derived from the key), and crypt's passwords for rclone."""
    result = dict(base, RESTIC_REPOSITORY=repository(config, remote),
                  RESTIC_PASSWORD=restic_password(key))
    result.update({k: v for k, v in env(key).items() if k.startswith("RCLONE_CONFIG_")})
    return result

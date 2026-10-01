"""cloud: what the Backup app (live-backup) and the backup job (run-backup)
share: the configuration, the cloud accounts of GNOME Online Accounts as
rclone remotes, the repository's password in the keyring, and restic.

The backups are restic repositories reached through rclone, whose remote
("cloud:") is defined in the environment from a GNOME Online Accounts
account at every use: Google Drive with the account's OAuth token,
Nextcloud (GOA's "owncloud") over WebDAV with its password. Nothing about
the account is stored here but its id.
"""
import datetime
import json
import os
import subprocess
import time

import gi

gi.require_version("Goa", "1.0")
gi.require_version("Secret", "1")
from gi.repository import GLib, Goa, Secret  # noqa: E402

CONFIG = os.path.expanduser("~/.config/live-backup/config.json")
STATUS = os.path.expanduser("~/.local/state/live-backup/status.json")
RCLONE_CONFIG = os.path.expanduser("~/.config/live-backup/rclone.conf")
EXCLUDES = "/usr/local/share/live-backup/excludes"
# GOA provider type -> what the app calls it
PROVIDERS = {"google": "Google Drive", "owncloud": "Nextcloud"}
REPO_DIR = "Ubuntu Backup"
REMOTE = "cloud"
SCHEMA = Secret.Schema.new("org.ubuntu.LiveBackup", Secret.SchemaFlags.NONE,
                           {"repository": Secret.SchemaAttributeType.STRING})
# restic's exit codes (0.17+)
RESTIC_NO_REPO, RESTIC_BAD_PASSWORD = 10, 12


def load_config():
    try:
        return json.load(open(CONFIG))
    except (OSError, ValueError):
        return None


def save_config(config):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        json.dump(config, f, indent=2)


def load_status():
    try:
        return json.load(open(STATUS))
    except (OSError, ValueError):
        return None


def save_status(status):
    os.makedirs(os.path.dirname(STATUS), exist_ok=True)
    with open(STATUS, "w") as f:
        json.dump(status, f, indent=2)


# --- GNOME Online Accounts ------------------------------------------------------

def goa_client():
    return Goa.Client.new_sync(None)


def usable(obj, provider=None):
    """A GOA account with files, of the provider (any of ours if None)."""
    account = obj.get_account()
    if account is None or obj.get_files() is None:
        return False
    return (account.props.provider_type == provider if provider
            else account.props.provider_type in PROVIDERS)


def accounts(client, provider):
    return [o for o in client.get_accounts() if usable(o, provider)]


def account_by_id(client, account_id):
    obj = client.lookup_by_id(account_id)
    return obj if obj is not None and usable(obj) else None


def describe(obj):
    account = obj.get_account()
    return PROVIDERS[account.props.provider_type], account.props.presentation_identity


# --- rclone -------------------------------------------------------------------------

def webdav_env(url, user, password):
    obscured = subprocess.run(["rclone", "obscure", "-"], input=password, text=True,
                              capture_output=True, check=True).stdout.strip()
    return {"TYPE": "webdav", "URL": url, "VENDOR": "nextcloud", "USER": user,
            "PASS": obscured}


def drive_env(access_token, expires_in):
    expiry = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=expires_in)
    # Only the access token: rclone can't refresh it (GOA does), so it is
    # fetched again for every job.
    token = {"access_token": access_token, "token_type": "Bearer",
             "expiry": expiry.isoformat(timespec="seconds")}
    return {"TYPE": "drive", "SCOPE": "drive", "TOKEN": json.dumps(token)}


def remote_env(obj):
    """(environment for rclone and restic, seconds it stays valid or None)."""
    account = obj.get_account()
    account.call_ensure_credentials_sync(None)
    if account.props.provider_type == "google":
        oauth2 = obj.get_oauth2_based()
        token, expires_in = oauth2.call_get_access_token_sync(None)
        if expires_in < 600:  # about to expire: wait for GOA's next one
            time.sleep(expires_in + 5)
            account.call_ensure_credentials_sync(None)
            token, expires_in = oauth2.call_get_access_token_sync(None)
        remote, valid = drive_env(token, expires_in), expires_in
    else:
        uri = GLib.Uri.parse(obj.get_files().props.uri, GLib.UriFlags.NONE)
        scheme = "https" if uri.get_scheme() == "davs" else "http"
        port = f":{uri.get_port()}" if uri.get_port() > 0 else ""
        url = f"{scheme}://{uri.get_host()}{port}{uri.get_path()}".rstrip("/")
        user = uri.get_user() or account.props.identity
        password = obj.get_password_based().call_get_password_sync("password", None)
        remote, valid = webdav_env(url, user, password), None
    os.makedirs(os.path.dirname(RCLONE_CONFIG), exist_ok=True)
    open(RCLONE_CONFIG, "a").close()  # empty: the remote is in the environment
    env = dict(os.environ, RCLONE_CONFIG=RCLONE_CONFIG)
    env.update({f"RCLONE_CONFIG_{REMOTE.upper()}_{k}": v for k, v in remote.items()})
    return env, valid


def remote_path(path):
    return f"{REMOTE}:{path.strip('/')}"


def rclone_args(*args):
    return ["rclone", "--contimeout", "20s", "--low-level-retries", "2", *args]


# --- the repository and its password -------------------------------------------

def repository(config):
    return f"rclone:{remote_path(config['repo'])}"


def store_password(repo, password):
    Secret.password_store_sync(SCHEMA, {"repository": repo}, Secret.COLLECTION_DEFAULT,
                               f"Backup password ({repo})", password, None)


def lookup_password(repo):
    return Secret.password_lookup_sync(SCHEMA, {"repository": repo}, None)


def restic_env(env, config, password):
    return dict(env, RESTIC_REPOSITORY=repository(config), RESTIC_PASSWORD=password)

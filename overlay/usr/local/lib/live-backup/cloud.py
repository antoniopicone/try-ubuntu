"""cloud: what the Backup app (live-backup) and the backup job (run-backup)
share: the configuration, the cloud accounts as rclone remotes, the
repository's password in the keyring, and restic.

The backups are restic repositories reached through rclone, on a remote
called "cloud:" made in one of two ways:
  - from a GNOME Online Accounts account, at every use, in the environment:
    Nextcloud (GOA's "owncloud") over WebDAV with its password, OneDrive
    (GOA's "ms_graph", Microsoft 365) with its OAuth token. Only the
    account's id is stored here.
  - with rclone's own sign-in (`rclone authorize`, in the browser) for
    Google Drive and Dropbox: Ubuntu's GOA has no Google Drive (built
    without its Files feature) and no Dropbox. rclone keeps the token, and
    renews it, in ~/.config/live-backup/rclone.conf (only the user's).
"""
import configparser
import datetime
import json
import os
import subprocess
import time
import urllib.request

import gi

gi.require_version("Goa", "1.0")
gi.require_version("Secret", "1")
from gi.repository import GLib, Goa, Secret  # noqa: E402

CONFIG = os.path.expanduser("~/.config/live-backup/config.json")
STATUS = os.path.expanduser("~/.local/state/live-backup/status.json")
RCLONE_CONFIG = os.path.expanduser("~/.config/live-backup/rclone.conf")
EXCLUDES = "/usr/local/share/live-backup/excludes"
# provider -> what the app calls it
PROVIDERS = {"google": "Google Drive", "dropbox": "Dropbox", "owncloud": "Nextcloud",
             "ms_graph": "OneDrive"}
# reached through a GNOME Online Accounts account (the GOA provider type)
GOA_PROVIDERS = {"owncloud", "ms_graph"}
# signed in with rclone: provider -> rclone backend
RCLONE_PROVIDERS = {"google": "drive", "dropbox": "dropbox"}
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
            else account.props.provider_type in GOA_PROVIDERS)


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


def onedrive_env(access_token, expires_in):
    expiry = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=expires_in)
    # Only the access token: rclone can't refresh it (GOA does), so it is
    # fetched again for every job.
    token = {"access_token": access_token, "token_type": "Bearer",
             "expiry": expiry.isoformat(timespec="seconds")}
    request = urllib.request.Request("https://graph.microsoft.com/v1.0/me/drive",
                                     headers={"Authorization": f"Bearer {access_token}"})
    drive = json.load(urllib.request.urlopen(request, timeout=30))
    return {"TYPE": "onedrive", "TOKEN": json.dumps(token), "DRIVE_ID": drive["id"],
            "DRIVE_TYPE": drive["driveType"]}


def _env(remote):
    os.makedirs(os.path.dirname(RCLONE_CONFIG), exist_ok=True)
    if not os.path.exists(RCLONE_CONFIG):
        open(RCLONE_CONFIG, "w").close()
    os.chmod(RCLONE_CONFIG, 0o600)
    env = dict(os.environ, RCLONE_CONFIG=RCLONE_CONFIG)
    env.update({f"RCLONE_CONFIG_{REMOTE.upper()}_{k}": v for k, v in remote.items()})
    return env


def goa_env(obj):
    """(environment for rclone and restic, seconds it stays valid or None)
    for a GOA account."""
    account = obj.get_account()
    account.call_ensure_credentials_sync(None)
    if account.props.provider_type == "ms_graph":
        oauth2 = obj.get_oauth2_based()
        token, expires_in = oauth2.call_get_access_token_sync(None)
        if expires_in < 600:  # about to expire: wait for GOA's next one
            time.sleep(expires_in + 5)
            account.call_ensure_credentials_sync(None)
            token, expires_in = oauth2.call_get_access_token_sync(None)
        remote, valid = onedrive_env(token, expires_in), expires_in
    else:
        uri = GLib.Uri.parse(obj.get_files().props.uri, GLib.UriFlags.NONE)
        scheme = "https" if uri.get_scheme() == "davs" else "http"
        port = f":{uri.get_port()}" if uri.get_port() > 0 else ""
        url = f"{scheme}://{uri.get_host()}{port}{uri.get_path()}".rstrip("/")
        user = uri.get_user() or account.props.identity
        password = obj.get_password_based().call_get_password_sync("password", None)
        remote, valid = webdav_env(url, user, password), None
    return _env(remote), valid


# --- rclone's own sign-in (Google Drive, Dropbox) -----------------------------

def authorize_cmd(provider):
    """`rclone authorize`: prints the sign-in URL (stderr), serves the
    redirect on 127.0.0.1:53682 and prints the token (stdout)."""
    return ["rclone", "authorize", RCLONE_PROVIDERS[provider], "--auth-no-open-browser"]


def token_from(output):
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("{"):
            return json.loads(line)
    return None


def save_rclone_remote(provider, token):
    """The signed-in remote, in rclone's config file (where rclone writes
    the renewed tokens back)."""
    config = configparser.ConfigParser()
    config[REMOTE] = {"type": RCLONE_PROVIDERS[provider], "token": json.dumps(token)}
    if provider == "google":
        config[REMOTE]["scope"] = "drive"
    os.makedirs(os.path.dirname(RCLONE_CONFIG), exist_ok=True)
    with open(os.open(RCLONE_CONFIG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        config.write(f)


def rclone_identity(env):
    """The signed-in user, when the backend tells (Dropbox does)."""
    out = subprocess.run(rclone_args("config", "userinfo", "--json", f"{REMOTE}:"), env=env,
                         capture_output=True, text=True)
    try:
        info = json.loads(out.stdout)
    except ValueError:
        return ""
    return info.get("Email") or info.get("Name") or ""


def env_for(config, client):
    """(environment, seconds it stays valid or None) for the configured
    backups; LookupError if their GOA account is gone."""
    if config.get("auth") == "rclone":
        return _env({}), None
    obj = account_by_id(client, config["account"])
    if obj is None:
        raise LookupError(config["account"])
    return goa_env(obj)


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

"""restore: bringing a backup back into the home folder, for the Cloud Backup app.

The newest backup (restic snapshot tagged live-backup) is restored into
this user's home folder, wherever it was backed up from (another user name,
another computer): `restic restore <snapshot>:<old home> --target ~`.
Nothing is deleted: files that are only here stay. Files that are in both
places take the backup's version; plan() says which, grouped the way a
person thinks of them (the terminal's settings, the profile picture...), and
counts what comes back by type.

Never restored: the keyring (sealed with the old password: it would replace
the new one, and the recovery key in it), the backups' own settings, the
iCloud session, caches. GNOME's settings (dconf) don't go over the running
session's database, which the session would write back over: they're
restored aside and loaded with `dconf load`. The profile picture, kept
outside the home by AccountsService, is in the backup as
~/.local/share/live-backup/face (run-backup copies it) and set back through
AccountsService.
"""
import json
import os
import shutil
import subprocess
import tempfile
from datetime import datetime

import cloud

TAG = "live-backup"
FACE = ".local/share/live-backup/face"
DCONF = ".config/dconf"
ACCOUNTS_ICON = "/var/lib/AccountsService/icons"
# Not restored (relative to the home folder)
SKIP = [".local/share/keyrings", ".config/live-backup", ".local/state/live-backup",
        ".config/autostart/org.ubuntu.LiveBackup.desktop", ".config/icloud-linux",
        ".cache", "iCloud", DCONF]

# What comes back, by type: (key, extensions)
TYPES = [
    ("documents", {"pdf", "doc", "docx", "odt", "rtf", "txt", "md", "pages", "tex", "epub",
                   "xls", "xlsx", "ods", "csv", "numbers", "ppt", "pptx", "odp", "key"}),
    ("pictures", {"jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "svg", "tif", "tiff",
                  "bmp", "raw", "cr2", "cr3", "nef", "arw", "dng", "xcf", "psd", "kra"}),
    ("videos", {"mp4", "mov", "mkv", "avi", "webm", "m4v", "mpg", "mpeg", "wmv"}),
    ("music", {"mp3", "flac", "wav", "ogg", "oga", "m4a", "aac", "opus", "wma", "aiff"}),
    ("archives", {"zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "iso", "dmg"}),
    ("code", {"py", "js", "ts", "tsx", "jsx", "rs", "go", "c", "h", "cpp", "hpp", "java",
              "kt", "swift", "rb", "php", "sh", "zsh", "html", "css", "scss", "json", "yaml",
              "yml", "toml", "sql", "ipynb", "lua", "cs", "dart"}),
]
# What it replaces, by what it is: (key, path prefixes); the first that
# matches wins, so the specific ones come first.
REPLACED = [
    ("terminal", [".config/ghostty/"]),
    ("gnome", [DCONF + "/"]),
    ("picture", [FACE]),
    ("shell", [".zshrc", ".zshenv", ".zprofile", ".zsh_history", ".bashrc", ".bash_profile",
               ".bash_logout", ".bash_history", ".profile", ".config/zsh/"]),
    ("git", [".gitconfig", ".config/git/"]),
    ("ssh", [".ssh/"]),
    ("browser", [".config/BraveSoftware/", ".config/chromium/", ".config/google-chrome/", ".mozilla/"]),
    ("extensions", [".local/share/gnome-shell/"]),
    ("flatpak", [".var/app/"]),
    ("apps", [".config/", ".local/share/", "."]),
    ("files", [""]),
]


# Their icons, in the order the app lists them
KIND_ICONS = {"documents": "x-office-document-symbolic", "pictures": "image-x-generic-symbolic",
              "videos": "video-x-generic-symbolic", "music": "audio-x-generic-symbolic",
              "archives": "package-x-generic-symbolic", "code": "applications-engineering-symbolic",
              "other": "text-x-generic-symbolic", "settings": "preferences-system-symbolic"}
REPLACED_ICONS = {"terminal": "utilities-terminal-symbolic",
                  "gnome": "preferences-desktop-appearance-symbolic",
                  "picture": "avatar-default-symbolic", "shell": "utilities-terminal-symbolic",
                  "git": "folder-publicshare-symbolic", "ssh": "dialog-password-symbolic",
                  "browser": "web-browser-symbolic", "extensions": "application-x-addon-symbolic",
                  "flatpak": "system-software-install-symbolic",
                  "apps": "preferences-other-symbolic", "files": "document-edit-symbolic"}


def _run(config, env, remote, *args):
    return subprocess.run(cloud.restic_cmd(config, *args, remote=remote), env=env,
                          capture_output=True, text=True)


def latest(config, env, remote=cloud.REMOTE):
    """The newest backup: {"id", "time" (datetime), "hostname", "home"}, or None."""
    out = _run(config, env, remote, "snapshots", "--json", "--tag", TAG)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "restic snapshots")
    snapshots = [s for s in json.loads(out.stdout or "[]") if s.get("paths")]
    if not snapshots:
        return None
    s = max(snapshots, key=lambda s: s["time"])
    return {"id": s["id"], "time": datetime.fromisoformat(s["time"]),
            "hostname": s.get("hostname", ""), "home": s["paths"][0].rstrip("/")}


def _skipped(rel):
    return any(rel == p or rel.startswith(p + "/") for p in SKIP if p != DCONF)


def kind_of(rel):
    if rel.startswith("."):
        return "settings"
    ext = rel.rsplit(".", 1)[-1].lower() if "." in os.path.basename(rel) else ""
    return next((k for k, exts in TYPES if ext in exts), "other")


def replaced_kind(rel):
    return next(k for k, prefixes in REPLACED
                if any(rel == p.rstrip("/") or rel.startswith(p) for p in prefixes))


def plan(config, env, snapshot, remote=cloud.REMOTE, home=cloud.HOME):
    """What restoring `snapshot` brings back and what it replaces:
    {"restore": {kind: files}, "replace": {kind: files}, "files", "bytes"}."""
    out = _run(config, env, remote, "ls", "--json", "--recursive", snapshot["id"],
               snapshot["home"])
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "restic ls")
    restore, replace, files, size = {}, {}, 0, 0
    prefix = snapshot["home"] + "/"
    for line in out.stdout.splitlines():
        node = json.loads(line)
        if node.get("struct_type") != "node" or node.get("type") != "file":
            continue
        rel = node["path"][len(prefix):] if node["path"].startswith(prefix) else None
        if not rel or _skipped(rel):
            continue
        files += 1
        size += node.get("size", 0)
        kind = kind_of(rel)
        restore[kind] = restore.get(kind, 0) + 1
        here = os.path.join(home, rel)
        if rel == FACE:  # the picture set now is AccountsService's
            icon = os.path.join(ACCOUNTS_ICON, os.path.basename(home.rstrip("/")))
            here = icon if os.path.isfile(icon) else here
        # Replaced: what is here too, in another version
        if os.path.isfile(here) and (os.path.getsize(here) != node.get("size", 0)
                                     or _differs(here, node)):
            kind = replaced_kind(rel)
            replace[kind] = replace.get(kind, 0) + 1
    return {"restore": restore, "replace": replace, "files": files, "bytes": size}


def _differs(path, node):
    """Same size: different if the backup's copy isn't from the same moment."""
    try:
        mtime = datetime.fromisoformat(node["mtime"]).timestamp()
    except (KeyError, ValueError):
        return True
    return abs(os.path.getmtime(path) - mtime) > 2


def restore(config, env, snapshot, on_progress=lambda fraction: None, remote=cloud.REMOTE,
            home=cloud.HOME):
    """Restore into the home folder, then GNOME's settings and the picture.
    Returns what couldn't be put back, without stopping the rest: a list of
    "gnome", "picture"."""
    excludes = [arg for p in SKIP for arg in ("--exclude", "/" + p)]
    proc = subprocess.Popen(
        cloud.restic_cmd(config, "restore", "--json", f"{snapshot['id']}:{snapshot['home']}",
                         "--target", home, *excludes, remote=remote),
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for line in proc.stdout:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if message.get("message_type") == "status":
            on_progress(message.get("percent_done", 0))
    err = proc.stderr.read()
    if proc.wait() != 0:
        raise RuntimeError(err.strip() or "restic restore")
    _drop_missing_defaults(home)
    problems = []
    for kind, step in (("gnome", _restore_dconf), ("picture", _restore_face)):
        try:
            step(config, env, snapshot, remote, home)
        except Exception:  # the files are back: say it, go on
            problems.append(kind)
    on_progress(1.0)
    return problems


def _drop_missing_defaults(home):
    """The backup's default apps (~/.config/mimeapps.list) may name apps that
    aren't installed here (an older image's browser): those lines go, so the
    system's defaults (Brave Origin...) apply instead of whatever GNOME
    would pick."""
    path = os.path.join(home, ".config", "mimeapps.list")
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return
    dirs = [os.path.join(home, ".local/share/applications"), "/usr/share/applications",
            "/usr/local/share/applications", "/var/lib/flatpak/exports/share/applications",
            os.path.join(home, ".local/share/flatpak/exports/share/applications")]

    def installed(desktop_id):
        return any(os.path.exists(os.path.join(d, desktop_id)) for d in dirs)
    kept = []
    for line in lines:
        key, sep, value = line.partition("=")
        if sep and not line.startswith(("[", "#")):
            ids = [i for i in value.split(";") if i and installed(i)]
            if not ids:
                continue
            line = f"{key}={';'.join(ids)};" if value.endswith(";") else f"{key}={';'.join(ids)}"
        kept.append(line)
    with open(path, "w") as f:
        f.write("\n".join(kept) + "\n")


def _restore_dconf(config, env, snapshot, remote, home):
    """GNOME's settings: the backup's dconf database, loaded into the session."""
    with tempfile.TemporaryDirectory() as tmp:
        out = _run(config, env, remote, "restore",
                   f"{snapshot['id']}:{snapshot['home']}/{DCONF}", "--target", tmp)
        db = os.path.join(tmp, "user")
        if out.returncode != 0 or not os.path.isfile(db):
            return  # not in the backup
        # Read it through a dconf profile of its own, then load it here
        name = f"live-backup-restore-{os.getpid()}"
        target = os.path.join(home, ".config/dconf", name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy(db, target)
        profile = os.path.join(tmp, "profile")
        with open(profile, "w") as f:
            f.write(f"user-db:{name}\n")
        try:
            dump = subprocess.run(["dconf", "dump", "/"], env=dict(os.environ, DCONF_PROFILE=profile),
                                  capture_output=True, text=True, check=True).stdout
        finally:
            os.remove(target)
        # The settings that name files in the home folder (the wallpaper):
        # the same files in this one, when the user's name changed
        if snapshot["home"].rstrip("/") != home.rstrip("/"):
            dump = dump.replace(snapshot["home"].rstrip("/") + "/", home.rstrip("/") + "/")
        subprocess.run(["dconf", "load", "/"], input=dump, text=True, capture_output=True,
                       check=True)


def _restore_face(config, env, snapshot, remote, home):
    """The profile picture, through AccountsService (each user may set theirs)."""
    face = os.path.join(home, FACE)
    if not os.path.isfile(face):
        return
    uid = os.getuid()
    found = subprocess.run(["gdbus", "call", "--system", "--dest", "org.freedesktop.Accounts",
                            "--object-path", "/org/freedesktop/Accounts", "--method",
                            "org.freedesktop.Accounts.FindUserById", str(uid)],
                           capture_output=True, text=True, check=True).stdout
    path = found.strip().strip("(),'")
    subprocess.run(["gdbus", "call", "--system", "--dest", "org.freedesktop.Accounts",
                    "--object-path", path, "--method",
                    "org.freedesktop.Accounts.User.SetIconFile", face],
                   capture_output=True, text=True, check=True)


def save_face(home=cloud.HOME):
    """For run-backup: a copy of the profile picture into the home folder,
    so that the backup has it."""
    user = os.path.basename(home.rstrip("/"))
    icon = os.path.join(ACCOUNTS_ICON, user)
    face = os.path.join(home, FACE)
    if os.path.isfile(icon) and os.access(icon, os.R_OK):
        os.makedirs(os.path.dirname(face), exist_ok=True)
        shutil.copy(icon, face)

"""apps: the apps the user installed, kept in the backup to install again
after a restore.

run-backup writes the list into the home folder before each backup
(~/.local/share/live-backup/apps.json), so it travels with the files:
  - Flatpak apps (GNOME Software's, from Flathub): id, remote and
    installation (system or user)
  - apt packages the user added: what apt-mark calls manually installed,
    less what the image itself has (its list, written at build time)

After a restore the Cloud Backup app offers to install again those that
aren't here: the Flatpak apps from their remotes, the packages through
install-packages (as root, through pkexec), which skips those the archive
doesn't have (from a repository added by hand, say).
"""
import json
import os
import re
import subprocess

import cloud

APPS = ".local/share/live-backup/apps.json"
IMAGE_PACKAGES = "/usr/local/share/live-backup/image-packages"
INSTALL_PACKAGES = "/usr/local/lib/live-backup/install-packages"
FLATPAK_ID = re.compile(r"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$")
PACKAGE = re.compile(r"^[a-z0-9][a-z0-9+.-]+$")


def _flatpaks():
    out = subprocess.run(["flatpak", "list", "--app", "--columns=application,origin,installation"],
                         capture_output=True, text=True)
    apps = []
    for line in out.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) == 3 and FLATPAK_ID.match(fields[0]):
            apps.append({"id": fields[0], "origin": fields[1], "installation": fields[2]})
    return apps


def _packages():
    """The packages installed by hand that the image doesn't have."""
    try:
        with open(IMAGE_PACKAGES) as f:
            image = set(f.read().split())
    except OSError:
        return []  # without the image's list, everything would look added
    out = subprocess.run(["apt-mark", "showmanual"], capture_output=True, text=True)
    return sorted(set(out.stdout.split()) - image)


def save(home=cloud.HOME):
    """For run-backup: the list into the home folder, to be backed up."""
    path = os.path.join(home, APPS)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w") as f:
        json.dump({"flatpak": _flatpaks(), "apt": _packages()}, f, indent=1)
    os.replace(path + ".tmp", path)


def missing(home=cloud.HOME):
    """The backed-up apps that aren't installed here:
    {"flatpak": [...], "apt": [...]}, or None when there are none."""
    try:
        with open(os.path.join(home, APPS)) as f:
            saved = json.load(f)
    except (OSError, ValueError):
        return None
    here = {app["id"] for app in _flatpaks()}
    flatpaks = [app for app in saved.get("flatpak", [])
                if isinstance(app, dict) and FLATPAK_ID.match(str(app.get("id", "")))
                and app["id"] not in here]
    packages = [p for p in saved.get("apt", []) if isinstance(p, str) and PACKAGE.match(p)]
    if packages:
        out = subprocess.run(["dpkg-query", "-W", "-f", "${Package} ${db:Status-Status}\n",
                              *packages], capture_output=True, text=True)
        installed = {line.split()[0] for line in out.stdout.splitlines()
                     if line.endswith(" installed")}
        packages = [p for p in packages if p not in installed]
    if not flatpaks and not packages:
        return None
    return {"flatpak": flatpaks, "apt": packages}


def reinstall(apps):
    """Install `apps` (from missing()) again. Returns what couldn't be: a
    list of names."""
    failed = []
    groups = {}
    for app in apps.get("flatpak", []):
        installation = "--user" if app.get("installation") == "user" else "--system"
        groups.setdefault((installation, app.get("origin") or "flathub"), []).append(app["id"])
    for (installation, origin), ids in groups.items():
        out = subprocess.run(["flatpak", "install", "-y", "--noninteractive", installation,
                              origin, *ids], capture_output=True, text=True)
        if out.returncode != 0:
            # One at a time: one that's gone from the remote doesn't keep the others out
            for app_id in ids:
                one = subprocess.run(["flatpak", "install", "-y", "--noninteractive",
                                      installation, origin, app_id], capture_output=True)
                if one.returncode != 0:
                    failed.append(app_id)
    if apps.get("apt"):
        out = subprocess.run(["pkexec", INSTALL_PACKAGES, *apps["apt"]],
                             capture_output=True, text=True)
        try:
            failed += json.loads(out.stdout.strip().splitlines()[-1])["missing"]
        except (ValueError, IndexError, KeyError):
            failed += apps["apt"]  # cancelled, or apt failed
    return failed

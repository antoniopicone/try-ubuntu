"""Nautilus: "Previous Versions" in the right-click menu of a file or folder
in /home (and of a folder's background), when snapper keeps snapshots of
/home. It opens /usr/local/bin/live-file-versions."""
import os
import subprocess

from gi.repository import GObject, Nautilus

SNAPSHOTS = "/home/.snapshots"
LABEL = {"it": "Versioni precedenti"}.get(os.environ.get("LANG", "")[:2], "Previous Versions")


def _path(item):
    location = item.get_location()
    path = location.get_path() if location else None
    if path and os.path.realpath(path).startswith("/home/") and os.path.isdir(SNAPSHOTS):
        return path
    return None


class FileVersions(GObject.GObject, Nautilus.MenuProvider):
    def _item(self, name, path):
        item = Nautilus.MenuItem(name=name, label=LABEL)
        item.connect("activate", lambda *_: subprocess.Popen(
            ["/usr/local/bin/live-file-versions", path], start_new_session=True))
        return [item]

    def get_file_items(self, files):
        if len(files) != 1:
            return []
        path = _path(files[0])
        return self._item("LiveFileVersions::file", path) if path else []

    def get_background_items(self, folder):
        path = _path(folder)
        return self._item("LiveFileVersions::folder", path) if path else []

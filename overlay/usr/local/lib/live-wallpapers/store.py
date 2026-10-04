"""store: what Wallpapers keeps on this computer.

  ~/.config/live-wallpapers/config.json   the sources that are on, Pixabay's
                                          key, the saved searches, the
                                          automatic change, the screen's size
  ~/.local/share/live-wallpapers/
      collection.json                     the wallpapers the user saved
      history.json                        the last ones set (the automatic
                                          change doesn't repeat them)
      images/                             the downloaded images
      thumbs/                             the collection's thumbnails

The images of the wallpapers in use, of the collection and of the history
stay; prune() deletes the others.
"""
import copy
import hashlib
import json
import os
import shutil
import urllib.request

import sources
from sources import Item

CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                      "live-wallpapers", "config.json")
DATA = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
                    "live-wallpapers")
IMAGES = os.path.join(DATA, "images")
THUMBS = os.path.join(DATA, "thumbs")
HISTORY = 30

DEFAULTS = {
    # Source id -> on; a source not listed here is on unless it says otherwise
    "sources": {},
    "pixabay_key": "",
    # "Match the theme": the accent color follows the wallpaper
    "match_theme": True,
    # [{"name": ..., "query": Query.to_dict()}]
    "searches": [],
    "auto": {
        "enabled": False,
        "from": "daily",      # daily, collection, search
        "search": "",         # a saved search's name
        "every": "daily",     # hourly, daily, weekly, login
        "metered": True,      # no downloads on metered networks
        "pair": False,        # a light wallpaper for the light style, a dark one for the dark
    },
    # The largest monitor, in pixels: the app writes it, rotate has no display to ask
    "screen": [1920, 1080],
}


def _read(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _write(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".part", "w", encoding="utf-8") as f:
        json.dump(value, f, indent=1, ensure_ascii=False)
    os.replace(path + ".part", path)


def load_config():
    config = copy.deepcopy(DEFAULTS)
    saved = _read(CONFIG, {})
    for key, value in saved.items():
        if isinstance(config.get(key), dict) and isinstance(value, dict):
            config[key].update(value)
        else:
            config[key] = value
    return config


def save_config(config):
    _write(CONFIG, config)
    os.chmod(CONFIG, 0o600)  # Pixabay's key


def saved_search(config, name):
    return next((s for s in config["searches"] if s["name"] == name), None)


# --- the collection and the history ---------------------------------------------------

def collection():
    return [Item.from_dict(d) for d in _read(os.path.join(DATA, "collection.json"), [])]


def in_collection(item):
    return any(saved.key == item.key for saved in collection())


def thumb_path(item):
    return os.path.join(THUMBS, item.key.replace("/", "_").replace(":", "-"))


def collect(item, keep):
    """Add the item to the collection, or take it out. Its thumbnail comes
    along, so the collection shows without the network."""
    items = [saved for saved in collection() if saved.key != item.key]
    if keep:
        items.insert(0, item)
        os.makedirs(THUMBS, exist_ok=True)
        with open(thumb_path(item), "wb") as f:
            f.write(sources.thumbnail(item.thumb))
    elif os.path.exists(thumb_path(item)):
        os.remove(thumb_path(item))
    _write(os.path.join(DATA, "collection.json"), [saved.to_dict() for saved in items])


def history():
    return [Item.from_dict(d) for d in _read(os.path.join(DATA, "history.json"), [])]


def remember(item):
    items = [item] + [old for old in history() if old.key != item.key]
    _write(os.path.join(DATA, "history.json"), [i.to_dict() for i in items[:HISTORY]])


# --- the images -----------------------------------------------------------------------

def image_path(item):
    name = item.key.replace("/", "_").replace(":", "-")
    extension = os.path.splitext(item.full.split("?")[0])[1].lower()
    return os.path.join(IMAGES, name + (extension if extension in (".png", ".webp") else ".jpg"))


def download(item, progress=None):
    """The item's full image, downloaded once: its path. progress(0..1) is
    called from this thread as it comes."""
    path = image_path(item)
    if os.path.exists(path):
        return path
    os.makedirs(IMAGES, exist_ok=True)
    request = urllib.request.Request(item.full, headers=sources.headers_for(item.full))
    try:
        with urllib.request.urlopen(request, timeout=30) as response, \
                open(path + ".part", "wb") as f:
            total = int(response.headers.get("Content-Length") or 0)
            done = 0
            while chunk := response.read(64 * 1024):
                f.write(chunk)
                done += len(chunk)
                if progress and total:
                    progress(min(1.0, done / total))
    except (OSError, ValueError) as e:
        if os.path.exists(path + ".part"):
            os.remove(path + ".part")
        raise sources.SourceError("network", str(e)) from e
    os.replace(path + ".part", path)
    return path


def rendered_path(item, settings):
    """Where an image with the preview's adjustments (position, blur,
    darkening) is written: one file per item and settings."""
    name = os.path.basename(image_path(item)).rsplit(".", 1)[0]
    digest = hashlib.sha1(repr(settings).encode()).hexdigest()[:6]
    return os.path.join(IMAGES, f"{name}-{digest}.jpg")


def prune(in_use=()):
    """Delete the downloaded images nothing refers to: not a wallpaper in use
    (paths), not in the collection, not among the last ones set."""
    keep = {os.path.basename(path) for path in in_use}
    stems = {os.path.basename(image_path(item)).rsplit(".", 1)[0]
             for item in collection() + history()[:5]}
    try:
        names = os.listdir(IMAGES)
    except OSError:
        return
    for name in names:
        # "<source>-<id>.jpg", or "<source>-<id>-<settings>.jpg" for a rendered one
        if name in keep or name.rsplit(".", 1)[0] in stems or name.endswith(".part"):
            continue
        os.remove(os.path.join(IMAGES, name))


def export(item, folder):
    """A copy of the downloaded image in `folder`, named after its title."""
    source = download(item)
    title = "".join(c for c in item.title if c.isalnum() or c in " -_").strip()[:60]
    os.makedirs(folder, exist_ok=True)
    target = os.path.join(folder, (title or item.key.replace(":", "-"))
                          + os.path.splitext(source)[1])
    shutil.copyfile(source, target)
    return target

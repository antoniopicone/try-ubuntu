"""desktop: Wallpapers' hands on the GNOME session.

  - the wallpaper: org.gnome.desktop.background's picture-uri (light style)
    and picture-uri-dark (dark style)
  - the accent color (org.gnome.desktop.interface): yaru-accent-sync then
    gives the Yaru icons the same color
  - the automatic change: live-wallpapers@<hourly|daily|weekly>.timer, or
    live-wallpapers.service itself at every login (systemd user units)
  - images as GDK textures, and a few of their pixels for palette.py

No widgets here: rotate uses it without a display.
"""
import subprocess

import gi

gi.require_version("Gdk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib  # noqa: E402

TIMERS = ("hourly", "daily", "weekly")
SERVICE = "live-wallpapers.service"


def _background():
    return Gio.Settings.new("org.gnome.desktop.background")


def _interface():
    return Gio.Settings.new("org.gnome.desktop.interface")


def style():
    """'dark' or 'light': the session's style."""
    return "dark" if _interface().get_string("color-scheme") == "prefer-dark" else "light"


def wallpapers():
    """{'light': path, 'dark': path} of the wallpapers in use ('' for one
    that isn't a local file)."""
    settings = _background()
    paths = {}
    for which, key in (("light", "picture-uri"), ("dark", "picture-uri-dark")):
        uri = settings.get_string(key)
        paths[which] = Gio.File.new_for_uri(uri).get_path() or "" if uri else ""
    return paths


def set_wallpaper(path, light=True, dark=True):
    settings = _background()
    uri = Gio.File.new_for_path(path).get_uri()
    if light:
        settings.set_string("picture-uri", uri)
    if dark:
        settings.set_string("picture-uri-dark", uri)
    # Fills the screen, cropped: the preview's own positions are rendered into the image
    settings.set_string("picture-options", "zoom")
    Gio.Settings.sync()


def accent():
    return _interface().get_string("accent-color")


def set_accent(name):
    _interface().set_string("accent-color", name)
    Gio.Settings.sync()


def metered():
    return Gio.NetworkMonitor.get_default().get_network_metered()


def texture(data):
    """An image's bytes as a texture. Any thread can call it. GDK reads JPEG
    and PNG itself, which is quick; the other formats go through gdk-pixbuf."""
    return Gdk.Texture.new_from_bytes(GLib.Bytes.new(data))


def texture_from_file(path, max_width, max_height):
    """A downloaded image as a texture no larger than that: scaled as it's
    read (only gdk-pixbuf can), or whole when gdk-pixbuf can't read it."""
    try:
        return Gdk.Texture.new_for_pixbuf(
            GdkPixbuf.Pixbuf.new_from_file_at_scale(path, max_width, max_height, True))
    except GLib.Error:
        return Gdk.Texture.new_from_filename(path)


def pixels(image, size=24):
    """size x size of a texture's pixels, evenly spread, as (r, g, b)."""
    downloader = Gdk.TextureDownloader.new(image)
    downloader.set_format(Gdk.MemoryFormat.R8G8B8A8)
    data, stride = downloader.download_bytes()
    data = data.get_data()
    width, height = image.get_width(), image.get_height()
    return [tuple(data[offset:offset + 3])
            for y in range(size) for x in range(size)
            for offset in [(y * height // size) * stride + (x * width // size) * 4]]


def save(image, path):
    """A rendered texture as a JPEG at `path`, or as a PNG next to it when
    gdk-pixbuf can't write JPEGs: the path written."""
    try:
        Gdk.pixbuf_get_from_texture(image).savev(path, "jpeg", ["quality"], ["92"])
        return path
    except GLib.Error:
        path = path.rsplit(".", 1)[0] + ".png"
        image.save_to_png(path)
        return path


def _systemctl(*args):
    return subprocess.run(["systemctl", "--user", *args], capture_output=True, text=True)


def schedule(every):
    """The automatic change: 'hourly', 'daily', 'weekly', 'login', or None to
    turn it off. Returns systemctl's error, or ''."""
    for timer in TIMERS:
        if timer != every:
            _systemctl("disable", "--now", f"live-wallpapers@{timer}.timer")
    if every != "login":
        _systemctl("disable", SERVICE)
    if every is None:
        return ""
    unit = SERVICE if every == "login" else f"live-wallpapers@{every}.timer"
    result = _systemctl("enable", *(() if every == "login" else ("--now",)), unit)
    return result.stderr.strip() if result.returncode else ""

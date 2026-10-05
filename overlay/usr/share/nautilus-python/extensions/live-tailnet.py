"""Nautilus: the devices of the Tailscale network (the folders of ~/Tailscale,
live-tailnet's mount).

  - A device's Properties get a "Tailscale" page: its addresses, system,
    Tailscale's version, owner.
  - A device's right-click menu copies its address or its name, and
    "Send Files…" picks files to send to it.
  - Any file's menu gets "Send with Taildrop", with the devices that can
    receive now.

Sending is copying into the device's folder, and Files itself is asked to
do it (org.gnome.Nautilus.FileOperations2): the copy shows in its
operations, with its progress, like any other. live-tailnet hands the file
to Taildrop and says how it went. What's known of the devices comes from its
$XDG_RUNTIME_DIR/live-tailnet/devices.json."""
import datetime
import json
import os

from gi.repository import Gdk, Gio, GLib, GObject, Gtk, Nautilus

STATE = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "live-tailnet", "devices.json")

STRINGS = {
    "en": {
        "copy_ip": "Copy IP Address", "copy_dns": "Copy Network Name", "send_files": "Send Files…",
        "send_to": "Send Files to {device}", "taildrop": "Send with Taildrop",
        "status": "Status", "online_direct": "Online, direct connection",
        "online_relay": "Online, through the relay {relay}", "online": "Online", "offline": "Offline",
        "ipv4": "IPv4 address", "ipv6": "IPv6 address", "dns": "Network name", "system": "System",
        "model": "Model", "version": "Tailscale version", "owner": "Owner", "last_seen": "Last seen",
        "key_expiry": "Key expires", "receives": "Receives files (Taildrop)", "yes": "Yes",
        "no_offline": "No: it's offline", "no_other": "No: it's someone else's device",
        "no": "No",
    },
    "it": {
        "copy_ip": "Copia indirizzo IP", "copy_dns": "Copia nome in rete", "send_files": "Invia file…",
        "send_to": "Invia file a {device}", "taildrop": "Invia con Taildrop",
        "status": "Stato", "online_direct": "In linea, collegamento diretto",
        "online_relay": "In linea, attraverso il relay {relay}", "online": "In linea",
        "offline": "Non in linea",
        "ipv4": "Indirizzo IPv4", "ipv6": "Indirizzo IPv6", "dns": "Nome in rete", "system": "Sistema",
        "model": "Modello", "version": "Versione di Tailscale", "owner": "Proprietario",
        "last_seen": "Ultimo contatto", "key_expiry": "Scadenza della chiave",
        "receives": "Riceve file (Taildrop)", "yes": "Sì",
        "no_offline": "No: non è in linea", "no_other": "No: è il dispositivo di un altro utente",
        "no": "No",
    },
}


def t(key, /, **kw):
    lang = os.environ.get("LANG", "")[:2]
    return STRINGS.get(lang, STRINGS["en"])[key].format(**kw)


_cache = (None, {"mount": "", "devices": {}})


def state():
    """live-tailnet's devices, read again when it rewrote them."""
    global _cache
    try:
        mtime = os.stat(STATE).st_mtime_ns
        if mtime != _cache[0]:
            with open(STATE, encoding="utf-8") as fh:
                _cache = (mtime, json.load(fh))
    except (OSError, ValueError):
        _cache = (None, {"mount": "", "devices": {}})
    return _cache[1]


def path_of(item):
    location = item.get_location()
    return location.get_path() if location else None


def device_of(item):
    """The device whose folder `item` is, or None."""
    path, tailnet = path_of(item), state()
    if path and tailnet["mount"] and os.path.dirname(path) == tailnet["mount"]:
        return tailnet["devices"].get(os.path.basename(path))
    return None


def when(iso):
    """A time of Tailscale's as the user's own, or "" for none."""
    try:
        date = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return ""
    return date.astimezone().strftime("%x %H:%M") if date.year > 1 else ""


def send(paths, device):
    """Have Files copy the files into the device's folder, as if they were
    dropped there: its own operation, with its progress and its errors.
    live-tailnet sends them, and tells how it went."""
    folder = Gio.File.new_for_path(os.path.join(state()["mount"], device["name"]))
    uris = [Gio.File.new_for_path(path).get_uri() for path in paths]
    Gio.bus_get_sync(Gio.BusType.SESSION).call(
        "org.gnome.Nautilus", "/org/gnome/Nautilus/FileOperations2",
        "org.gnome.Nautilus.FileOperations2", "CopyURIs",
        GLib.Variant("(assa{sv})", (uris, folder.get_uri(), {})),
        None, Gio.DBusCallFlags.NONE, -1, None, None)


def copy_text(text):
    Gdk.Display.get_default().get_clipboard().set(text)


def pick_and_send(device):
    def picked(dialog, result):
        try:
            files = dialog.open_multiple_finish(result)
        except Exception:   # GLib.Error: dismissed
            return
        paths = [f.get_path() for f in files if f.get_path()]
        if paths:
            send(paths, device)

    Gtk.FileDialog(title=t("send_to", device=device["name"])).open_multiple(None, None, picked)


class Tailnet(GObject.GObject, Nautilus.MenuProvider, Nautilus.PropertiesModelProvider):
    def get_models(self, files):
        device = device_of(files[0]) if len(files) == 1 else None
        if not device:
            return []
        if not device["online"]:
            status = t("offline")
        elif device["direct"]:
            status = t("online_direct")
        elif device["relay"]:
            status = t("online_relay", relay=device["relay"])
        else:
            status = t("online")
        if device["taildrop"]:
            receives = t("yes")
        elif not device["mine"]:
            receives = t("no_other")
        else:
            receives = t("no_offline") if not device["online"] else t("no")
        rows = [
            ("status", status),
            ("ipv4", device["ipv4"]), ("ipv6", device["ipv6"]), ("dns", device["dns"]),
            ("system", " ".join(filter(None, (device["os"], device["os_version"])))),
            ("model", device["model"]), ("version", device["tailscale"]),
            ("owner", device["owner"]),
            ("last_seen", "" if device["online"] else when(device["last_seen"])),
            ("key_expiry", when(device["key_expiry"])),
            ("receives", receives),
        ]
        model = Gio.ListStore.new(Nautilus.PropertiesItem)
        for key, value in rows:
            if value:
                model.append(Nautilus.PropertiesItem(name=t(key), value=value))
        return [Nautilus.PropertiesModel(title="Tailscale", model=model)]

    def get_file_items(self, files):
        if not files:
            return []
        tailnet = state()
        if not tailnet["mount"]:
            return []
        device = device_of(files[0]) if len(files) == 1 else None
        if device:
            items = []
            for name, label, text in (("ip", "copy_ip", device["ipv4"] or device["ipv6"]),
                                      ("dns", "copy_dns", device["dns"])):
                if text:
                    item = Nautilus.MenuItem(name=f"LiveTailnet::{name}", label=t(label))
                    item.connect("activate", lambda _item, text=text: copy_text(text))
                    items.append(item)
            if device["taildrop"]:
                item = Nautilus.MenuItem(name="LiveTailnet::send_files", label=t("send_files"))
                item.connect("activate", lambda _item: pick_and_send(device))
                items.append(item)
            return items

        # Files to send: not folders (Taildrop sends files), nor what is
        # already in a device's folder
        paths = [path_of(f) for f in files]
        if any(f.is_directory() or not path or path.startswith(tailnet["mount"] + "/")
               for f, path in zip(files, paths)):
            return []
        targets = [d for d in tailnet["devices"].values() if d["taildrop"]]
        if not targets:
            return []
        top = Nautilus.MenuItem(name="LiveTailnet::taildrop", label=t("taildrop"))
        menu = Nautilus.Menu()
        top.set_submenu(menu)
        for index, target in enumerate(sorted(targets, key=lambda d: d["name"].lower())):
            item = Nautilus.MenuItem(name=f"LiveTailnet::to_{index}", label=target["name"])
            item.connect("activate", lambda _item, target=target: send(paths, target))
            menu.append_item(item)
        return [top]

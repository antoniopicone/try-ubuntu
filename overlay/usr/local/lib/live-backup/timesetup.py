"""timesetup: the timezone and the clock, for Cloud Config's first run (after
the network, which finding the computer's position needs).

The places (cities, time zones, the map's shapes) come from
/usr/local/share/live-timezone/tzmap.json (scripts/build-tzmap.py), the
zones' rules from tzdata (zoneinfo). No GTK in here: tzmap.py draws.

Where the computer is, roughly, to suggest a timezone:
  - with a Wi-Fi card, from the access points in range (their addresses
    and signal strength, never their names), which BeaconDB looks up in its
    open database: right to some tens of metres
  - or else from the public IP address (geoip.ubuntu.com, as Ubuntu's
    installer does): right to the city or the province
Nothing is asked without a network, and nothing is kept.

The timezone itself is systemd's (timedatectl, which the first user may
call: /etc/polkit-1/rules.d/49-live-timezone.rules); the clock is kept
right by systemd-timesyncd (NTP), and the summer time changes come with
the zone's rules. "Follow me when I travel" is GNOME's automatic timezone
(gnome-settings-daemon, through GeoClue), which needs the location
services on.
"""
import datetime
import json
import math
import os
import re
import subprocess
import unicodedata
import urllib.request
import zoneinfo
from xml.etree import ElementTree

DATA = "/usr/local/share/live-timezone/tzmap.json"
BEACONDB = "https://api.beacondb.net/v1/geolocate"
GEOIP = "https://geoip.ubuntu.com/lookup"
USER_AGENT = "ubuntu-live-cloud-config/1.0"
# A position from Wi-Fi is this precise, in metres, or it's the service's
# own guess from the IP address
WIFI_ACCURACY = 5000
# Cities this close to a point (in degrees: some 25 km) are as good as the
# nearest one
NEARBY = 0.25

_zones = {}


def _zone(tz):
    if tz not in _zones:
        try:
            _zones[tz] = zoneinfo.ZoneInfo(tz)
        except (zoneinfo.ZoneInfoNotFoundError, ValueError, OSError):
            _zones[tz] = None  # a zone tzdata doesn't have (yet): UTC
    return _zones[tz]


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def utc_offset(tz, when=None):
    """Minutes east of UTC, now or at an (aware) datetime."""
    zone = _zone(tz)
    if zone is None:
        return 0
    return round((when or _now()).astimezone(zone).utcoffset().total_seconds() / 60)


def std_offset(tz):
    """The offset of the zone's standard time: the smaller of its winter's
    and its summer's."""
    year = _now().year
    return min(utc_offset(tz, datetime.datetime(year, month, 15, tzinfo=datetime.timezone.utc))
               for month in (1, 7))


def utc_label(minutes):
    """UTC+2, UTC−3:30."""
    hours, rest = divmod(abs(minutes), 60)
    return f"UTC{'−' if minutes < 0 else '+'}{hours}" + (f":{rest:02}" if rest else "")


def abbreviation(tz):
    """CEST, or nothing for the zones whose abbreviation is just the offset."""
    zone = _zone(tz)
    name = _now().astimezone(zone).tzname() if zone else ""
    return name if name and re.fullmatch(r"[A-Z]{2,6}", name) else ""


def next_change(tz):
    """The zone's next clock change within a year: (the first minute of the
    new time, as a UTC datetime; minutes the clocks move, positive forward),
    or None."""
    now = _now().replace(second=0, microsecond=0)
    start = utc_offset(tz, now)
    day = datetime.timedelta(days=1)
    for n in range(1, 371):
        after = utc_offset(tz, now + n * day)
        if after == start:
            continue
        low, high = now + (n - 1) * day, now + n * day
        while high - low > datetime.timedelta(minutes=1):
            middle = low + (high - low) / 2
            middle = middle.replace(second=0, microsecond=0)
            if utc_offset(tz, middle) == start:
                low = middle
            else:
                high = middle
        return high, after - start
    return None


def local_time(tz, when=None):
    """An (aware) datetime in the zone: now, or a UTC one."""
    return (when or _now()).astimezone(_zone(tz) or datetime.timezone.utc)


def _plain(text):
    """Lowercase, without accents: what a search compares."""
    return "".join(c for c in unicodedata.normalize("NFD", text.lower())
                   if not unicodedata.combining(c))


class City:
    __slots__ = ("name", "country", "lat", "lon", "tz", "std", "keys", "country_key")

    def __init__(self, name, country, lat, lon, tz, std, keys):
        self.name, self.country, self.lat, self.lon = name, country, lat, lon
        self.tz, self.std, self.keys = tz, std, keys
        self.country_key = _plain(country)

    @property
    def label(self):
        return f"{self.name}, {self.country}"


class Places:
    """The map's data: .land and .zones' rings ([lon*10, lat*10, ...]),
    .zone_offsets (minutes, per zone), .cities (biggest first)."""

    def __init__(self, path=DATA, lang=None):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        lang = lang or os.environ.get("LANG", "")[:2]
        italian = lang == "it"
        std = [std_offset(tz) for tz in data["tz"]]
        self.land = data["land"]
        self.zones = [zone["r"] for zone in data["zones"]]
        self.zone_offsets = [std[zone["t"]] for zone in data["zones"]]
        self._boxes = []
        for rings in self.zones:
            xs = [v for ring in rings for v in ring[0::2]]
            ys = [v for ring in rings for v in ring[1::2]]
            self._boxes.append((min(xs), min(ys), max(xs), max(ys)))
        self.cities = []
        for name, cc, lat, lon, tz, *local in data["cities"]:
            shown = local[0] if italian and local else name
            country = data["countries"].get(cc, [cc, cc])[1 if italian else 0]
            # Found by either name, whatever the language
            keys = tuple(dict.fromkeys(_plain(n) for n in (shown, name, *local)))
            self.cities.append(City(shown, country, lat / 100, lon / 100, data["tz"][tz],
                                    std[tz], keys))

    def zone_at(self, lon, lat):
        """The index of the zone drawn at this point, or None."""
        x, y = lon * 10, lat * 10
        for index, box in enumerate(self._boxes):
            if box[0] <= x <= box[2] and box[1] <= y <= box[3] and _inside(x, y, self.zones[index]):
                return index
        return None

    def nearest(self, lon, lat, offset=None, tz=None):
        """The city nearest to a point: among those of a standard offset
        (minutes) or of a timezone when there are any, of them all if not."""
        shrink = math.cos(math.radians(lat))
        near = []
        for rank, city in enumerate(self.cities):
            if (offset is not None and city.std != offset) or (tz is not None and city.tz != tz):
                continue
            dx = (city.lon - lon + 180) % 360 - 180
            near.append((math.hypot(dx * shrink, city.lat - lat), rank))
        if not near:
            return self.nearest(lon, lat) if offset is not None or tz is not None else None
        # The biggest of those about as near: Istanbul, not the district of
        # it the point falls in
        reach = min(near)[0] + NEARBY
        return self.cities[min(rank for distance, rank in near if distance <= reach)]

    def pick(self, lon, lat):
        """The city a click on the map means: the nearest one in the time
        zone drawn there."""
        zone = self.zone_at(lon, lat)
        return self.nearest(lon, lat, offset=None if zone is None else self.zone_offsets[zone])

    def in_timezone(self, tz):
        """The biggest city of a timezone, or None."""
        return next((city for city in self.cities if city.tz == tz), None)

    def search(self, query, limit=8):
        """Cities by the start of their name, then of a word in it, then of
        their country's name; the biggest first."""
        q = _plain(query.strip())
        if not q:
            return []
        found = ([], [], [])
        for city in self.cities:
            rank = 3
            for key in city.keys:
                if key.startswith(q):
                    rank = 0
                elif rank > 1 and (f" {q}" in key or f"-{q}" in key):
                    rank = 1
            if rank == 3 and len(q) >= 3 and city.country_key.startswith(q):
                rank = 2
            if rank < 3 and len(found[rank]) < limit:
                found[rank].append(city)
            if len(found[0]) == limit:
                break
        return (found[0] + found[1] + found[2])[:limit]


def _inside(x, y, rings):
    hit = False
    for ring in rings:
        n = len(ring) // 2
        j = n - 1
        for i in range(n):
            xi, yi, xj, yj = ring[2 * i], ring[2 * i + 1], ring[2 * j], ring[2 * j + 1]
            if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
                hit = not hit
            j = i
    return hit


# --- where the computer is ---------------------------------------------------------------

def _fetch(url, body=None, timeout=8):
    headers = {"User-Agent": USER_AGENT}
    if body is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=body, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as reply:
        return reply.read(65536)


def access_points():
    """The Wi-Fi access points in range, as the geolocation API wants them:
    [{"macAddress", "signalStrength" (dBm)}]. The last scan's: no rescan."""
    try:
        out = subprocess.run(["nmcli", "-t", "-e", "yes", "-f", "BSSID,SIGNAL", "device", "wifi",
                              "list", "--rescan", "no"], capture_output=True, text=True,
                             timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    points = {}
    for line in out.splitlines():
        m = re.fullmatch(r"((?:[0-9A-Fa-f]{2}\\:){5}[0-9A-Fa-f]{2}):(\d+)", line.strip())
        if m:
            # NetworkManager's 0-100 quality back to dBm, as it derives it
            points[m[1].replace("\\", "").lower()] = int(m[2]) // 2 - 100
    return [{"macAddress": mac, "signalStrength": dbm} for mac, dbm in points.items()]


def _locate_wifi():
    points = access_points()
    if len(points) < 2:  # one could be a phone's hotspot, anywhere
        return None
    reply = json.loads(_fetch(BEACONDB, json.dumps(
        {"considerIp": False, "wifiAccessPoints": points[:30]}).encode()))
    if reply.get("fallback") or reply.get("accuracy", WIFI_ACCURACY + 1) > WIFI_ACCURACY:
        return None
    place = reply["location"]
    return {"lat": float(place["lat"]), "lon": float(place["lng"]), "tz": None, "source": "wifi"}


def _locate_ip():
    reply = ElementTree.fromstring(_fetch(GEOIP))
    lat, lon = reply.findtext("Latitude"), reply.findtext("Longitude")
    if reply.findtext("Status") != "OK" or not lat or not lon:
        return None
    tz = reply.findtext("TimeZone") or ""
    return {"lat": float(lat), "lon": float(lon), "tz": tz if _valid(tz) else None,
            "source": "ip"}


def locate():
    """Where the computer is: {"lat", "lon", "tz" (or None), "source":
    "wifi" or "ip"}, or None when neither way finds it. Blocks for some
    seconds: not for the main loop."""
    for way in (_locate_wifi, _locate_ip):
        try:
            place = way()
        except (OSError, ValueError, KeyError, TypeError, ElementTree.ParseError):
            place = None
        if place and -90 <= place["lat"] <= 90 and -180 <= place["lon"] <= 180:
            return place
    return None


# --- the system --------------------------------------------------------------------------

def _valid(tz):
    return bool(re.fullmatch(r"[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}", tz or "")) \
        and _zone(tz) is not None


def current_timezone():
    """The system's timezone, or None while it's still on UTC (as the
    image is until this is done)."""
    try:
        tz = os.path.realpath("/etc/localtime").split("/zoneinfo/", 1)[1]
    except IndexError:
        return None
    return None if tz in ("UTC", "Etc/UTC", "Universal") else tz


def is_laptop():
    """A computer that travels: a real one (not a VM) in a portable case."""
    try:
        if subprocess.run(["systemd-detect-virt", "--quiet"]).returncode == 0:
            return False
        chassis = int(open("/sys/class/dmi/id/chassis_type").read().strip())
    except (OSError, ValueError):
        return False
    # SMBIOS chassis types: portable, laptop, notebook, hand held, sub
    # notebook, tablet, convertible, detachable
    return chassis in (8, 9, 10, 11, 14, 30, 31, 32)


def _run(*command):
    out = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        message = (out.stderr or out.stdout).strip()
        raise RuntimeError(message.splitlines()[-1] if message else f"{command[0]} failed")


def apply(tz, ntp=True, automatic=False):
    """Sets the system's timezone, whether the clock follows the network's
    time (NTP) and whether the timezone follows the computer (GNOME's
    automatic timezone, which needs the location services). Raises
    RuntimeError with timedatectl's reason."""
    if not _valid(tz):
        raise RuntimeError(f"unknown timezone: {tz}")
    _run("timedatectl", "set-timezone", tz)
    _run("timedatectl", "set-ntp", "true" if ntp else "false")
    if automatic:
        _run("gsettings", "set", "org.gnome.system.location", "enabled", "true")
    _run("gsettings", "set", "org.gnome.desktop.datetime", "automatic-timezone",
         "true" if automatic else "false")

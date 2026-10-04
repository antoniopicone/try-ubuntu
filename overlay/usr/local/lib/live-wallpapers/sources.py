"""sources: the photo services Wallpapers searches, one class each.

  - Openverse: Creative Commons and public-domain images from Flickr,
    StockSnap, Wikimedia Commons and others. Anonymous: 20 searches a
    minute, 200 a day, 1000 thumbnails a day
  - Art Institute of Chicago, Cleveland Museum of Art: their public-domain
    (CC0) works, no key
  - NASA: its image library, no key
  - Wallhaven: wallpapers uploaded by its users, no key for the safe ones
    (45 requests a minute). It doesn't say whose they are or under which
    license, so it's off until the user turns it on
  - Pixabay: needs the user's own (free) API key

Unsplash and Pexels aren't here: their API terms forbid wallpaper apps.

Every search is one HTTP GET, answered from a disk cache while it's fresh
(the services' anonymous quotas are small; Pixabay asks for 24 hours).
search_all() asks the usable sources at once and deals their results like
cards. No GTK here: rotate (the automatic change) uses it too.
"""
import datetime
import hashlib
import json
import os
import random
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field

UA = "try-ubuntu-wallpapers/1.0 (+https://github.com/antoniopicone/try-ubuntu)"
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
                     "live-wallpapers")
HOUR = 3600
# What a result can be (the "Type" filter)
KINDS = ("photo", "painting", "illustration", "print", "space", "anime")
SORTS = ("relevance", "popular", "latest", "random")


class SourceError(Exception):
    """A service that didn't answer: .reason is 'limit' (too many requests),
    'key' (it refused the API key) or 'network'."""

    def __init__(self, reason, detail=""):
        super().__init__(detail or reason)
        self.reason = reason


@dataclass
class Item:
    source: str
    id: str
    title: str = ""
    creator: str = ""
    # cc0, pdm (public domain), by, by-sa..., or "" when the service says nothing
    license: str = ""
    thumb: str = ""
    full: str = ""
    page: str = ""
    width: int = 0   # of the image `full` downloads; 0: unknown
    height: int = 0
    kind: str = "photo"

    @property
    def key(self):
        return f"{self.source}:{self.id}"

    @property
    def free(self):
        return self.license in ("cc0", "pdm")

    def to_dict(self):
        return asdict(self)

    @classmethod
    def from_dict(cls, data):
        return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})


@dataclass
class Query:
    text: str = ""
    kinds: list = field(default_factory=list)  # of KINDS; empty: any
    color: str = ""                            # of palette.COLORS; "": any
    fit: bool = False                          # landscape, at least the screen's size
    free: bool = False                         # CC0 and public domain only
    sort: str = "relevance"
    sources: list = field(default_factory=list)  # ids; empty: every enabled one
    screen: tuple = (1920, 1080)

    def to_dict(self):
        data = asdict(self)
        del data["screen"]
        return data

    @classmethod
    def from_dict(cls, data, screen=(1920, 1080)):
        fields = {k: v for k, v in data.items() if k in cls.__dataclass_fields__}
        return cls(**fields, screen=tuple(screen))


# --- HTTP, with a disk cache -------------------------------------------------------

def headers_for(url):
    """What a request to that URL says about us. The Art Institute of Chicago
    asks for a header of its own, on its images too (403 without)."""
    host = urllib.parse.urlsplit(url).hostname or ""
    return {"User-Agent": UA, **({"AIC-User-Agent": UA} if host.endswith("artic.edu") else {})}


def fetch(url, timeout=25):
    request = urllib.request.Request(url, headers=headers_for(url))
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as e:
        reason = {429: "limit", 401: "key", 403: "key"}.get(e.code, "network")
        raise SourceError(reason, f"HTTP {e.code}") from e
    except (OSError, ValueError) as e:  # URLError, timeouts, a broken reply
        raise SourceError("network", str(e)) from e


def _cache_file(folder, key, suffix=""):
    path = os.path.join(CACHE, folder)
    os.makedirs(path, exist_ok=True)
    return os.path.join(path, hashlib.sha1(key.encode()).hexdigest() + suffix)


def _write(path, data):
    with open(path + ".part", "wb") as f:
        f.write(data)
    os.replace(path + ".part", path)


def get_json(url, ttl=6 * HOUR):
    path = _cache_file("api", url, ".json")
    try:
        if time.time() - os.path.getmtime(path) < ttl:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
    except (OSError, ValueError):
        pass
    data = fetch(url)
    try:
        parsed = json.loads(data)
    except ValueError as e:
        raise SourceError("network", "not JSON") from e
    _write(path, data)
    return parsed


def thumbnail(url):
    """A thumbnail's bytes, kept on disk."""
    path = _cache_file("thumbs", url)
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        data = fetch(url)
        _write(path, data)
        return data


def cached(name, ttl, make):
    """make()'s (JSON) value, kept for ttl seconds under that name."""
    path = _cache_file("made", name, ".json")
    try:
        if time.time() - os.path.getmtime(path) < ttl:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
    except (OSError, ValueError):
        pass
    value = make()
    if value:
        _write(path, json.dumps(value).encode())
    return value


def sweep():
    """Empties the cache of what's old: thumbnails downloaded over a month
    ago, answers over a week ago."""
    for folder, days in (("thumbs", 30), ("api", 7), ("made", 7)):
        try:
            entries = list(os.scandir(os.path.join(CACHE, folder)))
        except OSError:
            continue
        for entry in entries:
            if time.time() - entry.stat().st_mtime > days * 24 * HOUR:
                os.remove(entry.path)


def _url(base, params):
    return base + "?" + urllib.parse.urlencode(params)


# --- the services ------------------------------------------------------------------

class Source:
    id = name = ""
    kinds = KINDS          # what it has
    free = True            # has CC0 and public-domain works (search_all keeps only those)
    needs_key = False
    colors = False         # filters by color itself
    default = True         # on until the user turns it off

    def usable(self, query, config):
        """Can this search be asked here?"""
        return bool(config["sources"].get(self.id, self.default)
                    and (not self.needs_key or config.get(self.id + "_key"))
                    and (not query.sources or self.id in query.sources)
                    and (not query.kinds or set(query.kinds) & set(self.kinds))
                    and (self.free or not query.free))

    def search(self, query, page, config):
        raise NotImplementedError


class Openverse(Source):
    id, name = "openverse", "Openverse"
    kinds = ("photo", "illustration", "painting", "print")
    CATEGORIES = {"photo": "photograph", "illustration": "illustration",
                  "painting": "digitized_artwork", "print": "digitized_artwork"}

    def search(self, query, page, config):
        params = {"q": query.text or "landscape", "page": page, "page_size": 20}
        categories = {self.CATEGORIES[k] for k in query.kinds if k in self.CATEGORIES}
        if categories:
            params["category"] = ",".join(sorted(categories))
        if query.free:  # otherwise every Creative Commons license
            params["license"] = "cc0,pdm"
        if query.fit:
            params.update(aspect_ratio="wide", size="large")
        data = get_json(_url("https://api.openverse.org/v1/images/", params))
        kinds = {"illustration": "illustration", "digitized_artwork": "painting"}
        return [Item(self.id, r["id"], r.get("title") or "", r.get("creator") or "",
                     r.get("license") or "", r.get("thumbnail") or r["url"], r["url"],
                     r.get("foreign_landing_url") or "", r.get("width") or 0,
                     r.get("height") or 0, kinds.get(r.get("category"), "photo"))
                for r in data.get("results", []) if r.get("url")]


class Artic(Source):
    id, name = "artic", "Art Institute of Chicago"
    kinds = ("painting", "print")
    TYPES = {"painting": "Painting", "print": "Print"}
    # Its IIIF server gives public-domain works up to this width
    MAX_WIDTH = 3000

    def search(self, query, page, config):
        types = [self.TYPES[k] for k in query.kinds if k in self.TYPES] or ["Painting", "Print"]
        params = [("limit", 20), ("page", page),
                  ("fields", "id,title,artist_title,image_id,thumbnail,artwork_type_title"),
                  ("query[bool][must][0][term][is_public_domain]", "true")]
        params += [("query[bool][must][1][terms][artwork_type_title.keyword][]", t)
                   for t in types]
        if query.text:
            params.append(("q", query.text))
        else:  # nothing asked for: the museum's highlights
            params.append(("query[bool][must][2][term][is_boosted]", "true"))
        data = get_json(_url("https://api.artic.edu/api/v1/artworks/search", params))
        kinds = {v: k for k, v in self.TYPES.items()}
        items = []
        for a in data.get("data", []):
            size = a.get("thumbnail") or {}
            if not a.get("image_id") or not size.get("width"):
                continue
            iiif = f"https://www.artic.edu/iiif/2/{a['image_id']}/full/%d,/0/default.jpg"
            width = min(self.MAX_WIDTH, size["width"])
            items.append(Item(self.id, str(a["id"]), a.get("title") or "",
                              a.get("artist_title") or "", "cc0", iiif % 400, iiif % width,
                              f"https://www.artic.edu/artworks/{a['id']}", width,
                              round(size["height"] * width / size["width"]),
                              kinds.get(a.get("artwork_type_title"), "painting")))
        return items


class Cleveland(Source):
    id, name = "cleveland", "Cleveland Museum of Art"
    kinds = ("painting", "print")
    TYPES = {"painting": "Painting", "print": "Print"}

    def search(self, query, page, config):
        kinds = [k for k in query.kinds if k in self.TYPES] or ["painting"]
        per_kind = 20 // len(kinds)
        lists = []
        for kind in kinds:  # the API takes one type at a time
            params = {"cc0": 1, "has_image": 1, "type": self.TYPES[kind], "limit": per_kind,
                      "skip": (page - 1) * per_kind, "q": query.text or "landscape"}
            data = get_json(_url("https://openaccess-api.clevelandart.org/api/artworks/",
                                 params))
            lists.append([self._item(a, kind) for a in data.get("data", [])
                          if (a.get("images") or {}).get("print")])
        return deal(lists)

    def _item(self, a, kind):
        images = a["images"]
        creators = a.get("creators") or [{}]
        return Item(self.id, str(a["id"]), a.get("title") or "",
                    # "Thomas Cole (American, born England, 1801–1848)"
                    (creators[0].get("description") or "").split(" (")[0], "cc0",
                    (images.get("web") or images["print"])["url"], images["print"]["url"],
                    a.get("url") or "", int(images["print"].get("width") or 0),
                    int(images["print"].get("height") or 0), kind)


class Nasa(Source):
    id, name = "nasa", "NASA"
    kinds = ("space",)

    def search(self, query, page, config):
        params = {"q": query.text or "nebula", "media_type": "image", "page": page,
                  "page_size": 20}
        data = get_json(_url("https://images-api.nasa.gov/search", params))
        items = []
        for entry in data.get("collection", {}).get("items", []):
            meta = (entry.get("data") or [{}])[0]
            links = {link.get("rel"): link for link in entry.get("links") or []}
            original = links.get("canonical")
            preview = links.get("preview") or original
            if not meta.get("nasa_id") or not original:
                continue
            full = original["href"]
            if not full.lower().endswith((".jpg", ".jpeg")):
                # The originals can be huge TIFFs and PNGs: every image has this one too
                full = full.rsplit("~", 1)[0] + "~large.jpg"
            items.append(Item(self.id, meta["nasa_id"], meta.get("title") or "",
                              meta.get("secondary_creator") or meta.get("photographer")
                              or "NASA", "pdm", preview["href"].replace("http://", "https://"),
                              full.replace("http://", "https://"),
                              "https://images.nasa.gov/details/" + meta["nasa_id"],
                              original.get("width") or 0, original.get("height") or 0, "space"))
        return items


class Wallhaven(Source):
    id, name = "wallhaven", "Wallhaven"
    kinds = ("photo", "illustration", "anime")
    free = False
    colors = True
    default = False
    # The colors its search knows, closest to the filter's
    COLORS = {"red": "cc0000", "orange": "ff6600", "yellow": "ffff00", "green": "669900",
              "teal": "66cccc", "blue": "0066cc", "purple": "663399", "pink": "ea4c88",
              "brown": "996633", "white": "ffffff", "gray": "999999", "black": "000000"}

    def search(self, query, page, config):
        anime = "anime" in query.kinds
        general = not query.kinds or set(query.kinds) & {"photo", "illustration"}
        sorting = {"popular": "toplist", "latest": "date_added", "random": "random"}.get(
            query.sort, "relevance" if query.text else "toplist")
        params = {"q": query.text, "purity": "100", "page": page, "sorting": sorting,
                  "categories": f"{int(bool(general))}{int(anime)}0", "topRange": "1y"}
        if query.fit:
            params.update(atleast="%dx%d" % query.screen, ratios="landscape")
        if query.color:
            params["colors"] = self.COLORS[query.color]
        data = get_json(_url("https://wallhaven.cc/api/v1/search", params))
        return [Item(self.id, w["id"], "", "", "", w["thumbs"]["large"], w["path"], w["url"],
                     w.get("dimension_x") or 0, w.get("dimension_y") or 0,
                     "anime" if w.get("category") == "anime" else "photo")
                for w in data.get("data", [])]


class Pixabay(Source):
    id, name = "pixabay", "Pixabay"
    kinds = ("photo", "illustration")
    free = False  # Pixabay's own license
    needs_key = True
    colors = True
    COLORS = {"teal": "turquoise", "purple": "lilac"}  # the others have the filter's names
    LANGS = ("cs da de en es fr id it hu nl no pl pt ro sk fi sv tr vi th bg ru el ja ko "
             "zh").split()
    # Without an approved "full API access", the largest image it gives
    MAX_WIDTH = 1280

    def search(self, query, page, config):
        lang = os.environ.get("LANG", "")[:2]
        types = set(query.kinds) & {"photo", "illustration"}
        params = {"key": config["pixabay_key"], "q": query.text, "page": page,
                  "per_page": 20, "safesearch": "true",
                  "lang": lang if lang in self.LANGS else "en",
                  "order": "latest" if query.sort == "latest" else "popular",
                  "image_type": "all" if len(types) == 2 else "".join(types) or "photo"}
        if query.fit:
            params["orientation"] = "horizontal"
        if query.color:
            params["colors"] = self.COLORS.get(query.color, query.color)
        try:  # its terms ask to keep every answer for a day
            data = get_json(_url("https://pixabay.com/api/", params), ttl=24 * HOUR)
        except SourceError as e:
            # A wrong key is a plain "400 Bad Request" here
            raise SourceError("key" if "400" in str(e) else e.reason, str(e)) from e
        items = []
        for h in data.get("hits", []):
            width = min(self.MAX_WIDTH, h["imageWidth"])
            items.append(Item(self.id, str(h["id"]), h.get("tags") or "", h.get("user") or "",
                              "pixabay", h["webformatURL"], h["largeImageURL"], h["pageURL"],
                              width, round(h["imageHeight"] * width / h["imageWidth"]),
                              "illustration" if h.get("type", "").startswith("illustration")
                              else "photo"))
        return items


SOURCES = [Openverse(), Artic(), Cleveland(), Nasa(), Wallhaven(), Pixabay()]
BY_ID = {source.id: source for source in SOURCES}
# Left out, and why (shown under "Sources"): name, the terms that say so
UNAVAILABLE = [
    ("Unsplash", "https://help.unsplash.com/en/articles/2511245-unsplash-api-guidelines"),
    ("Pexels", "https://www.pexels.com/api/documentation/"),
]


def deal(lists):
    """Several lists into one, a result from each in turn."""
    lists = [list(items) for items in lists]
    dealt = []
    while any(lists):
        dealt += [items.pop(0) for items in lists if items]
    return dealt


def fits(item, query):
    """Landscape and at least as large as the screen (when the size is known)."""
    if not query.fit or not item.width:
        return True
    return (item.width > item.height and item.width >= query.screen[0]
            and item.height >= query.screen[1])


def search_all(query, config, page=1):
    """One page of results from every usable source: (items, {source id:
    SourceError.reason} for those that failed)."""
    usable = [source for source in SOURCES if source.usable(query, config)]

    def ask(source):
        try:
            return [item for item in source.search(query, page, config)
                    if fits(item, query) and (not query.free or item.free)]
        except SourceError as e:
            return e
        except (KeyError, TypeError, ValueError) as e:  # an answer in another shape
            return SourceError("network", repr(e))

    with ThreadPoolExecutor(max_workers=len(usable) or 1) as pool:
        answers = list(pool.map(ask, usable))
    errors = {source.id: answer.reason for source, answer in zip(usable, answers)
              if isinstance(answer, SourceError)}
    lists = [answer for answer in answers if not isinstance(answer, SourceError)]
    if query.sort == "random":
        for items in lists:
            random.shuffle(items)
    return deal(lists), errors


# --- what Discover shows -----------------------------------------------------------

# The moods: key (translated by the app), the search behind it
MOODS = {
    "nature": Query("mountain lake", ["photo"]),
    "space": Query("nebula", ["space"]),
    "aurora": Query("aurora borealis", ["photo"]),
    "city": Query("city night skyline", ["photo"]),
    "fog": Query("forest fog", ["photo"]),
    "sea": Query("ocean waves", ["photo"]),
    "dunes": Query("sand dunes desert", ["photo"]),
}
# The photo of the day comes from one of these, in turn
DAILY = [("nasa", "nebula"), ("artic", ""), ("openverse", "mountain landscape"),
         ("cleveland", "landscape"), ("openverse", "aurora borealis"), ("artic", "landscape"),
         ("nasa", "galaxy"), ("openverse", "ocean coast")]
# "Surprise me" searches one of these (and the moods)
SURPRISES = ["waterfall", "milky way", "autumn forest", "snow mountain", "tropical beach",
             "canyon", "volcano", "lavender field", "northern lights", "coral reef",
             "starry night", "rice terraces", "glacier", "lighthouse", "wildflowers",
             "impressionism", "ukiyo-e landscape", "saturn", "earth from orbit", "galaxy"]


def _landscape(items):
    return [item for item in items if item.width > item.height]


def _free_query(text, config, source=""):
    return Query(text, free=True, sources=[source] if source else [],
                 screen=tuple(config["screen"]))


def daily(config, day=None):
    """The photo of the day: the same for the whole day, a public-domain one
    from one of the enabled sources. None when none of them answers."""
    day = day or datetime.date.today()

    def pick():
        for turn in range(len(DAILY)):
            source, text = DAILY[(day.toordinal() + turn) % len(DAILY)]
            items = _landscape(search_all(_free_query(text, config, source), config)[0])
            if items:
                return items[day.toordinal() // len(DAILY) % len(items)].to_dict()
        return None
    item = cached(f"daily-{day}", 48 * HOUR, pick)
    return Item.from_dict(item) if item else None


def highlights(config, day=None, n=4):
    """A few museum works for today."""
    day = day or datetime.date.today()

    def pick():
        query = Query("", ["painting"], free=True, sources=["artic", "cleveland"],
                      screen=tuple(config["screen"]))
        items = _landscape(search_all(query, config)[0])
        random.Random(day.toordinal()).shuffle(items)
        return [item.to_dict() for item in items[:n]]
    return [Item.from_dict(item) for item in cached(f"highlights-{day}", 48 * HOUR, pick) or []]


def mood_cover(key, config):
    """The picture on a mood's tile: its search's first landscape result, kept
    for a week."""
    query = MOODS[key]

    def pick():
        items = _landscape(search_all(
            Query(query.text, query.kinds, free=True, screen=tuple(config["screen"])),
            config)[0])
        return items[0].to_dict() if items else None
    item = cached(f"mood-{key}", 7 * 24 * HOUR, pick)
    return Item.from_dict(item) if item else None


def surprise(config):
    """A random wallpaper: a random result of a random search."""
    texts = SURPRISES + [query.text for query in MOODS.values()]
    random.shuffle(texts)
    for text in texts[:4]:
        items = _landscape(search_all(_free_query(text, config), config,
                                      random.randint(1, 3))[0])
        if items:
            return random.choice(items)
    return None


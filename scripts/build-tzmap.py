#!/usr/bin/env python3
"""build-tzmap.py [DOWNLOADS_DIR]: the world map of Cloud Config's timezone
step (overlay/usr/local/share/live-timezone/tzmap.json, which is committed:
run this by hand to refresh it).

The land is Natural Earth's (1:110m, public domain). The time zones are
timezone-boundary-builder's (from OpenStreetMap, ODbL): the "now" set, which
joins the zones that keep the same time from now on and covers the seas
too, simplified to what a 700 px wide map shows. The cities are GeoNames'
(CC BY 4.0): those of 100 000 people and more, the capitals, and the
biggest city of every other timezone, with their Italian names:

  {"land": [ring, ...],
   "zones": [{"t": index in "tz", "r": [ring, ...]}, ...],
   "tz": ["Africa/Abidjan", ...],
   "cities": [[name, country code, lat*100, lon*100, index in "tz",
               Italian name when it differs], ...],      biggest first
   "countries": {"IT": ["Italy", "Italia"], ...}}

A ring is [lon*10, lat*10, lon*10, lat*10, ...].

The downloads (250 MB, mostly GeoNames' alternate names) are kept in
DOWNLOADS_DIR (default: a temporary directory).
"""
import io
import json
import os
import sys
import tempfile
import urllib.request
import zipfile

NATURAL_EARTH = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
# The release follows tzdata's: a newer one when zones change
BOUNDARIES = "https://github.com/evansiroky/timezone-boundary-builder/releases/download/2026d/"
GEONAMES = "https://download.geonames.org/export/dump/"
SOURCES = {
    "ne_110m_land.geojson": NATURAL_EARTH,
    "timezones-with-oceans-now.geojson.zip": BOUNDARIES,
    "cities15000.zip": GEONAMES,
    "countryInfo.txt": GEONAMES,
    "alternateNamesV2.zip": GEONAMES,
}
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "overlay", "usr", "local",
                   "share", "live-timezone", "tzmap.json")
MIN_POPULATION = 100000
# In degrees: how far a simplified border may stray, and the islands and
# enclaves too small to draw
ZONE_TOLERANCE = 0.12
ZONE_MIN_SIZE = 0.5
LAND_MIN_SIZE = 0.6


def fetch(directory):
    for name, base in SOURCES.items():
        path = os.path.join(directory, name)
        if not os.path.exists(path):
            print(f"==> Downloading {name}", file=sys.stderr)
            urllib.request.urlretrieve(base + name, path + ".part")
            os.rename(path + ".part", path)


def simplify(points, tolerance):
    """Douglas-Peucker."""
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        a, b = stack.pop()
        ax, ay = points[a]
        bx, by = points[b]
        dx, dy = bx - ax, by - ay
        norm = (dx * dx + dy * dy) ** 0.5
        worst, index = 0, None
        for i in range(a + 1, b):
            px, py = points[i]
            d = (abs(dy * (px - ax) - dx * (py - ay)) / norm if norm
                 else ((px - ax) ** 2 + (py - ay) ** 2) ** 0.5)
            if d > worst:
                worst, index = d, i
        if index is not None and worst > tolerance:
            keep[index] = True
            stack += [(a, index), (index, b)]
    return [p for p, k in zip(points, keep) if k]


def rings_of(geometry, tolerance, min_size):
    polygons = (geometry["coordinates"] if geometry["type"] == "MultiPolygon"
                else [geometry["coordinates"]])
    rings = []
    for polygon in polygons:
        for ring in polygon:
            xs, ys = [p[0] for p in ring], [p[1] for p in ring]
            if max(xs) - min(xs) < min_size and max(ys) - min(ys) < min_size:
                continue
            points = [(p[0], p[1]) for p in ring]
            flat, last = [], None
            for x, y in simplify(points, tolerance) if tolerance else points:
                point = (round(x * 10), round(y * 10))
                if point != last:
                    flat += point
                    last = point
            if len(flat) >= 8:
                rings.append(flat)
    return rings


def italian_names(directory, ids):
    """{geonameid: Italian name} for these ids: the preferred name, or else
    the first that is neither historic nor colloquial."""
    names, preferred = {}, set()
    with zipfile.ZipFile(os.path.join(directory, "alternateNamesV2.zip")) as archive:
        with archive.open("alternateNamesV2.txt") as raw:
            for line in io.TextIOWrapper(raw, encoding="utf-8"):
                c = line.rstrip("\n").split("\t")
                if c[2] != "it" or c[1] not in ids or c[6:8] != ["", ""]:
                    continue
                if c[4] == "1" and c[1] not in preferred:
                    names[c[1]] = c[3]
                    preferred.add(c[1])
                else:
                    names.setdefault(c[1], c[3])
    return names


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="tzmap-")
    os.makedirs(directory, exist_ok=True)
    fetch(directory)

    land = []
    for feature in json.load(open(os.path.join(directory, "ne_110m_land.geojson")))["features"]:
        land += rings_of(feature["geometry"], 0, LAND_MIN_SIZE)

    zones = []
    with zipfile.ZipFile(os.path.join(directory,
                                      "timezones-with-oceans-now.geojson.zip")) as archive:
        with archive.open(archive.namelist()[0]) as raw:
            for feature in json.load(raw)["features"]:
                rings = rings_of(feature["geometry"], ZONE_TOLERANCE, ZONE_MIN_SIZE)
                if rings:
                    zones.append({"tz": feature["properties"]["tzid"], "r": rings})

    rows = []
    with zipfile.ZipFile(os.path.join(directory, "cities15000.zip")) as archive:
        with archive.open("cities15000.txt") as raw:
            for line in io.TextIOWrapper(raw, encoding="utf-8"):
                c = line.rstrip("\n").split("\t")
                # Not the districts of a city (PPLX: Paris's arrondissements)
                if c[17] and c[7] != "PPLX":
                    rows.append({"id": c[0], "name": c[1], "lat": float(c[4]),
                                 "lon": float(c[5]), "capital": c[7] == "PPLC", "cc": c[8],
                                 "population": int(c[14]), "tz": c[17]})
    rows.sort(key=lambda r: -r["population"])
    seen, cities = set(), []
    for row in rows:
        if row["population"] >= MIN_POPULATION or row["capital"] or row["tz"] not in seen:
            cities.append(row)
        seen.add(row["tz"])

    countries = {}
    for line in open(os.path.join(directory, "countryInfo.txt"), encoding="utf-8"):
        c = line.rstrip("\n").split("\t")
        if not line.startswith("#") and len(c) > 16:
            countries[c[0]] = {"id": c[16], "name": c[4]}
    italian = italian_names(directory, {c["id"] for c in cities}
                            | {c["id"] for c in countries.values()})

    tzs = sorted({c["tz"] for c in cities} | {z["tz"] for z in zones})
    index = {tz: i for i, tz in enumerate(tzs)}
    data = {
        "land": land,
        "zones": [{"t": index[z["tz"]], "r": z["r"]} for z in zones],
        "tz": tzs,
        "cities": [[c["name"], c["cc"], round(c["lat"] * 100), round(c["lon"] * 100),
                    index[c["tz"]]]
                   + ([italian[c["id"]]] if italian.get(c["id"], c["name"]) != c["name"] else [])
                   for c in cities],
        "countries": {cc: [c["name"], italian.get(c["id"], c["name"])]
                      for cc, c in sorted(countries.items())
                      if any(city["cc"] == cc for city in cities)},
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as out:
        json.dump(data, out, ensure_ascii=False, separators=(",", ":"))
        out.write("\n")
    print(f"{os.path.normpath(OUT)}: {os.path.getsize(OUT) // 1024} KiB, {len(cities)} cities, "
          f"{len(tzs)} timezones, {len(zones)} zones", file=sys.stderr)


if __name__ == "__main__":
    main()

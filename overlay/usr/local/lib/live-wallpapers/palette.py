"""palette: what Wallpapers knows about an image's colors, from a few of its
pixels (a thumbnail scaled down to 24x24: see desktop.pixels()).

  - names(): which of the color filter's colors (COLORS) the image has, for
    the services that can't filter by color themselves
  - palette(): its main colors, shown in the preview
  - accent(): the GNOME accent color closest to it ("Match the theme")
  - brightness(): how light it is, to pair a wallpaper for the light style
    with one for the dark style

Pixels are (r, g, b) tuples, 0-255.
"""
import colorsys
from collections import Counter

# The color filter's swatches
COLORS = {
    "red": "#e62d42", "orange": "#ed5b00", "yellow": "#f5c211", "green": "#3a944a",
    "teal": "#2190a4", "blue": "#3584e4", "purple": "#9141ac", "pink": "#d56199",
    "brown": "#865e3c", "white": "#f6f5f4", "gray": "#77767b", "black": "#000000",
}
# GNOME's accent colors (libadwaita's)
ACCENTS = {
    "blue": "#3584e4", "teal": "#2190a4", "green": "#3a944a", "yellow": "#c88800",
    "orange": "#ed5b00", "red": "#e62d42", "pink": "#d56199", "purple": "#9141ac",
    "slate": "#6f8396",
}
# An image has a color when this share of its pixels does
SHARE = 0.12


def rgb(color):
    """'#rrggbb' -> (r, g, b)."""
    return tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))


def _hls(pixel):
    h, l, s = colorsys.rgb_to_hls(*(c / 255 for c in pixel))
    return h * 360, l, s


def name(pixel):
    """The color of the filter a pixel counts as."""
    hue, light, saturation = _hls(pixel)
    if light < 0.1:
        return "black"
    if light > 0.9:
        return "white"
    if saturation < 0.15:
        return "white" if light > 0.8 else "black" if light < 0.18 else "gray"
    # Brown is a dark, muted orange
    if 12 <= hue < 50 and light < 0.42 and saturation < 0.75:
        return "brown"
    for limit, color in ((15, "red"), (40, "orange"), (70, "yellow"), (160, "green"),
                         (200, "teal"), (255, "blue"), (290, "purple"), (345, "pink")):
        if hue < limit:
            return color
    return "red"


def names(pixels):
    """The filter's colors an image has: those of a good share of its pixels."""
    counts = Counter(name(p) for p in pixels)
    return {color for color, n in counts.items() if n >= SHARE * len(pixels)}


def palette(pixels, n=5):
    """The image's n main colors as '#rrggbb', the most common first, no two
    of them close to each other."""
    buckets = {}
    for p in pixels:
        buckets.setdefault(tuple(c >> 5 for c in p), []).append(p)
    colors = []
    for group in sorted(buckets.values(), key=len, reverse=True):
        color = tuple(sum(p[i] for p in group) // len(group) for i in range(3))
        if all(sum((a - b) ** 2 for a, b in zip(color, other)) > 48 ** 2 for other in colors):
            colors.append(color)
        if len(colors) == n:
            break
    return ["#%02x%02x%02x" % c for c in colors]


def accent(pixels):
    """The GNOME accent color closest to the image's colors: the hue most of
    its color is in, or slate when that color is faint (a foggy forest, ice)
    or the image has hardly any."""
    hues = {key: _hls(rgb(color))[0] for key, color in ACCENTS.items() if key != "slate"}
    weights, counts = Counter(), Counter()
    for p in pixels:
        hue, light, saturation = _hls(p)
        if saturation < 0.15 or not 0.15 <= light <= 0.85:
            continue
        nearest = min(hues, key=lambda key: min(abs(hue - hues[key]), 360 - abs(hue - hues[key])))
        weights[nearest] += saturation
        counts[nearest] += 1
    if sum(weights.values()) < 0.05 * len(pixels):
        return "slate"
    best = weights.most_common(1)[0][0]
    return best if weights[best] / counts[best] >= 0.25 else "slate"


def brightness(pixels):
    """0 (black) to 1 (white)."""
    return sum(0.2126 * r + 0.7152 * g + 0.0722 * b for r, g, b in pixels) / (255 * len(pixels))

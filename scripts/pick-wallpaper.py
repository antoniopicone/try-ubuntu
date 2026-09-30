#!/usr/bin/env python3
"""Picks one of Ubuntu's stock wallpapers at random.

Usage: pick-wallpaper.py ROOTFS

The candidates are the wallpapers the GNOME background descriptions in
ROOTFS list (ubuntu-wallpapers, which Ubuntu's gnome-shell depends on).
Prints the light and the dark picture's path (the same one for a wallpaper
without a dark variant). Slideshows (.xml) and WebP pictures (no loader in
the image) are skipped.
"""
import os
import random
import sys
import xml.etree.ElementTree as ET

rootfs = sys.argv[1]
props = rootfs + "/usr/share/gnome-background-properties"

candidates = []
for name in sorted(os.listdir(props)):
    for wallpaper in ET.parse(os.path.join(props, name)).getroot().iter("wallpaper"):
        light = wallpaper.findtext("filename")
        dark = wallpaper.findtext("filename-dark") or light
        if all(f.endswith((".png", ".jpg")) and os.path.isfile(rootfs + f)
               and not os.path.islink(rootfs + f) for f in (light, dark)):
            candidates.append((wallpaper.findtext("name"), light, dark))

name, light, dark = random.choice(candidates)
print(f"==> Wallpaper: {name} ({light}, {dark})", file=sys.stderr)
print(light, dark)

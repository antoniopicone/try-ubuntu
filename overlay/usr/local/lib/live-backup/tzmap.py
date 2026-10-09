"""tzmap: the world map of Cloud Config's timezone step.

    import tzmap
    world = tzmap.TimezoneMap(timesetup.Places(), on_pick)
    world.set_city(city)

The land, with the time zones' borders over it and, under it, a scale of
the hours from UTC. The zones that share the chosen city's standard time
are filled in the accent color, and the city has a pin with its name and
its time. Moving the pointer shows which city a click would pick (the
nearest one in the zone under it: timesetup.Places.pick), and a click
calls on_pick(city).

An equirectangular map, cut above 84° north and below 58° south: a degree
is as wide everywhere, so the hours' scale lines up with the zones.
"""
import math

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Adw, GLib, Gtk, PangoCairo  # noqa: E402

import timesetup  # noqa: E402

WIDTH = 720.0           # the map's own units: 2 per degree
LAT_TOP, LAT_BOTTOM = 84.0, -58.0
HEIGHT = WIDTH * (LAT_TOP - LAT_BOTTOM) / 360
SCALE = 24              # the hours' scale under the map, in pixels
RADIUS = 12
EVEN_ODD = 1            # cairo.FillRule.EVEN_ODD: zones have enclaves


def _x(lon):
    return (lon + 180) / 360 * WIDTH


def _y(lat):
    return (LAT_TOP - lat) / (LAT_TOP - LAT_BOTTOM) * HEIGHT


class TimezoneMap(Gtk.DrawingArea):
    def __init__(self, places, on_pick, **kwargs):
        super().__init__(hexpand=True, **kwargs)
        self.places, self.on_pick = places, on_pick
        self.city = self.hover = None
        self._paths = {}
        self._by_offset = {}
        for rings, offset in zip(places.zones, places.zone_offsets):
            self._by_offset.setdefault(offset, []).extend(rings)
        self.set_draw_func(self._draw)
        self.set_cursor_from_name("pointer")
        motion = Gtk.EventControllerMotion()
        motion.connect("motion", self._on_motion)
        motion.connect("leave", lambda *_: self._set_hover(None))
        self.add_controller(motion)
        click = Gtk.GestureClick()
        click.connect("released", self._on_click)
        self.add_controller(click)
        style = Adw.StyleManager.get_default()
        for prop in ("dark", "accent-color"):
            style.connect(f"notify::{prop}", lambda *_: self.queue_draw())

    def set_city(self, city):
        self.city = city
        self.queue_draw()

    # --- size: as tall as the width makes the map, plus the scale ---------------------

    def do_get_request_mode(self):
        return Gtk.SizeRequestMode.HEIGHT_FOR_WIDTH

    def do_measure(self, orientation, for_size):
        if orientation == Gtk.Orientation.HORIZONTAL:
            return 280, int(WIDTH), -1, -1
        height = round((for_size if for_size > 0 else WIDTH) * HEIGHT / WIDTH) + SCALE
        return height, height, -1, -1

    # --- pointer ----------------------------------------------------------------------

    def _city_at(self, x, y):
        width, height = self.get_width(), self.get_height() - SCALE
        if width <= 0 or height <= 0 or not 0 <= x <= width or not 0 <= y <= height:
            return None
        return self.places.pick(x / width * 360 - 180,
                                LAT_TOP - y / height * (LAT_TOP - LAT_BOTTOM))

    def _set_hover(self, city):
        if city is not self.hover:
            self.hover = city
            self.queue_draw()

    def _on_motion(self, _controller, x, y):
        self._set_hover(self._city_at(x, y))

    def _on_click(self, _gesture, _n, x, y):
        city = self._city_at(x, y)
        if city:
            self.on_pick(city)

    # --- drawing ----------------------------------------------------------------------

    def _path(self, cr, key, rings):
        """The rings' path, in the map's units; built once."""
        cr.new_path()
        if key in self._paths:
            cr.append_path(self._paths[key])
            return
        for ring in rings:
            cr.move_to(_x(ring[0] / 10), _y(ring[1] / 10))
            for i in range(2, len(ring), 2):
                cr.line_to(_x(ring[i] / 10), _y(ring[i + 1] / 10))
            cr.close_path()
        self._paths[key] = cr.copy_path()

    def _layout(self, text, small=False, bold=False):
        layout = self.create_pango_layout(None)
        markup = GLib.markup_escape_text(text)
        if bold:
            markup = f"<b>{markup}</b>"
        layout.set_markup(f'<span size="{"x-small" if small else "small"}">{markup}</span>')
        return layout

    def _tag(self, cr, text, x, y, width, height, fill, ink):
        """A label next to a city's point: on its right, or on its left
        where the right has no room."""
        layout = self._layout(text, bold=True)
        w, h = layout.get_pixel_size()
        w, h = w + 16, h + 6
        left = x + 10 if x + 10 + w <= width - 4 else x - 10 - w
        top = min(max(y - h / 2, 4), height - h - 4)
        cr.new_path()
        _rounded(cr, left, top, w, h, 7)
        cr.set_source_rgba(*fill)
        cr.fill()
        cr.set_source_rgba(*ink)
        cr.move_to(left + 8, top + 3)
        PangoCairo.show_layout(cr, layout)

    def _draw(self, _area, cr, width, height):
        style = Adw.StyleManager.get_default()
        dark = style.get_dark()
        fg = self.get_color()
        fg = (fg.red, fg.green, fg.blue)
        accent = style.get_accent_color_rgba()
        accent = (accent.red, accent.green, accent.blue)
        sea = (0.16, 0.17, 0.20) if dark else (0.93, 0.94, 0.96)
        land = (0.34, 0.33, 0.37) if dark else (0.78, 0.76, 0.79)
        card = (0.21, 0.21, 0.23) if dark else (1.0, 1.0, 1.0)
        map_height = height - SCALE
        k = width / WIDTH
        chosen = self.city.std if self.city else None
        hover = self.hover.std if self.hover else None

        _rounded(cr, 0, 0, width, height, RADIUS)
        cr.clip()
        cr.set_source_rgb(*sea)
        cr.paint()

        cr.save()
        cr.rectangle(0, 0, width, map_height)
        cr.clip()
        cr.scale(k, map_height / HEIGHT)
        cr.set_fill_rule(EVEN_ODD)
        self._path(cr, "land", self.places.land)
        cr.set_source_rgb(*land)
        cr.fill()
        if hover is not None and hover != chosen and hover in self._by_offset:
            self._path(cr, hover, self._by_offset[hover])
            cr.set_source_rgba(*fg, 0.09)
            cr.fill()
        if chosen in self._by_offset:
            self._path(cr, chosen, self._by_offset[chosen])
            cr.set_source_rgba(*accent, 0.55 if dark else 0.42)
            cr.fill()
        self._path(cr, "zones", [ring for rings in self.places.zones for ring in rings])
        cr.set_source_rgba(*fg, 0.17)
        cr.set_line_width(0.6 / k)
        cr.stroke()
        cr.restore()

        # The hours from UTC, each under the middle of its nominal zone
        cr.set_source_rgb(*card)
        cr.rectangle(0, map_height, width, SCALE)
        cr.fill()
        cr.set_source_rgba(*fg, 0.13)
        cr.rectangle(0, map_height, width, 1)
        cr.fill()
        for hours in range(-11, 12):
            if width < 520 and hours % 2:
                continue
            marked = chosen == hours * 60
            sign = "+" if hours > 0 else "−" if hours < 0 else ""
            layout = self._layout(f"{sign}{abs(hours)}", small=True,
                                  bold=marked or hover == hours * 60)
            w, h = layout.get_pixel_size()
            x = _x(hours * 15) * k - w / 2
            y = map_height + 1 + (SCALE - 1 - h) / 2
            if marked:
                cr.new_path()
                _rounded(cr, x - 4, y - 1, w + 8, h + 2, 5)
                cr.set_source_rgb(*accent)
                cr.fill()
                cr.set_source_rgb(1, 1, 1)
            else:
                cr.set_source_rgba(*fg, 0.9 if hover == hours * 60 else 0.6)
            cr.move_to(x, y)
            PangoCairo.show_layout(cr, layout)

        if self.hover and self.hover is not self.city:
            x, y = _x(self.hover.lon) * k, _y(self.hover.lat) * map_height / HEIGHT
            # new_path: the text drawn before leaves a current point, which
            # an arc would start with a line from
            cr.new_path()
            cr.arc(x, y, 3.5, 0, 2 * math.pi)
            cr.set_source_rgb(*card)
            cr.fill_preserve()
            cr.set_source_rgb(*fg)
            cr.set_line_width(1.5)
            cr.stroke()
            offset = timesetup.utc_label(timesetup.utc_offset(self.hover.tz))
            self._tag(cr, f"{self.hover.name}  {offset}", x, y, width, map_height,
                      (*card, 0.95), (*fg, 1.0))
        if self.city:
            x, y = _x(self.city.lon) * k, _y(self.city.lat) * map_height / HEIGHT
            cr.new_path()
            cr.arc(x, y, 5, 0, 2 * math.pi)
            cr.set_source_rgb(*accent)
            cr.fill_preserve()
            cr.set_source_rgb(1, 1, 1)
            cr.set_line_width(1.5)
            cr.stroke()
            time = timesetup.local_time(self.city.tz).strftime("%H:%M")
            self._tag(cr, f"{self.city.name}  {time}", x, y, width, map_height,
                      (*accent, 1.0), (1.0, 1.0, 1.0, 1.0))

        cr.reset_clip()
        cr.new_path()
        _rounded(cr, 0.5, 0.5, width - 1, height - 1, RADIUS)
        cr.set_source_rgba(*fg, 0.13)
        cr.set_line_width(1)
        cr.stroke()


def _rounded(cr, x, y, width, height, radius):
    cr.new_sub_path()
    cr.arc(x + width - radius, y + radius, radius, -math.pi / 2, 0)
    cr.arc(x + width - radius, y + height - radius, radius, 0, math.pi / 2)
    cr.arc(x + radius, y + height - radius, radius, math.pi / 2, math.pi)
    cr.arc(x + radius, y + radius, radius, math.pi, 3 * math.pi / 2)
    cr.close_path()

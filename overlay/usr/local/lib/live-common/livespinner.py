"""livespinner: a spinner for the live system's apps (welcome, Cloud Backup,
Previous Versions), in place of Adw.Spinner.

libadwaita 1.9's Adw.Spinner stays on its first frame when GNOME Shell has
animations off, which it does whenever the desktop renders in software
(llvmpipe: a VM without GPU acceleration): GTK still gets frame ticks, the
spinner just doesn't move, even with gtk-enable-animations forced on. This
one draws itself on every frame tick: an arc in the accent color that turns
and breathes, like Adwaita's.

    import livespinner
    spinner = livespinner.Spinner(size=48)
"""
import math

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

TURN_SECONDS = 1.2      # one turn of the arc
BREATH_SECONDS = 2.4    # the arc grows and shrinks over this
LINE = 0.11             # line width, as a share of the size


class Spinner(Gtk.DrawingArea):
    def __init__(self, size=32, **kwargs):
        super().__init__(content_width=size, content_height=size,
                         halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER, **kwargs)
        self._time = 0.0
        self.set_draw_func(self._draw)
        self.add_tick_callback(self._tick)

    def _tick(self, _widget, clock):
        self._time = clock.get_frame_time() / 1e6
        self.queue_draw()
        return True

    def _draw(self, _area, cr, width, height):
        size = min(width, height)
        line = max(2.0, size * LINE)
        radius = (size - line) / 2
        cx, cy = width / 2, height / 2
        # The track, faint
        fg = self.get_color()
        cr.set_line_width(line)
        cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.15)
        cr.arc(cx, cy, radius, 0, 2 * math.pi)
        cr.stroke()
        # The arc, in the accent color
        accent = Adw.StyleManager.get_default().get_accent_color_rgba()
        cr.set_source_rgba(accent.red, accent.green, accent.blue, 1.0)
        cr.set_line_cap(1)  # round
        start = (self._time / TURN_SECONDS) * 2 * math.pi
        breath = (math.sin(self._time / BREATH_SECONDS * 2 * math.pi) + 1) / 2
        length = math.pi * (0.25 + 1.15 * breath)
        cr.arc(cx, cy, radius, start, start + length)
        cr.stroke()

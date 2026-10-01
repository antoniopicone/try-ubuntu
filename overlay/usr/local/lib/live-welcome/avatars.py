"""avatars: the welcome app's avatar editor.

The avatars are DiceBear's CC0 styles (Open Peeps, Lorelei, Notionists,
Pixel Art, Thumbs), composed here from the JSON the build makes of them
(scripts/dicebear.py): no network, nothing sent anywhere. One picks a style,
then its parts (hair, eyes...) with arrows and its colors with swatches, or
lets chance do it; the result is a PNG for AccountsService.
"""
import io
import json
import random
import re
from xml.sax.saxutils import quoteattr

import cairo
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Rsvg", "2.0")
from gi.repository import Adw, Gdk, GLib, GObject, Gtk, Rsvg  # noqa: E402

STYLES = "/usr/local/share/live-welcome/dicebear.json"
SIZE = 512
# DiceBear's pastels, for the styles that have no backgrounds of their own
BACKGROUNDS = ["b6e3f4", "c0aede", "d1d4f9", "ffd5dc", "ffdfbf"]
# Labels that depend on the style: Open Peeps' "head" is the hair (and
# hats), its "face" the expression.
LABELS = {("open-peeps", "head"): "part_hair", ("open-peeps", "face"): "part_expression"}

CSS = """
.swatch { min-width: 26px; min-height: 26px; padding: 0; border-radius: 9999px;
          box-shadow: inset 0 0 0 1px alpha(black, 0.15); }
.swatch:checked { outline: 2px solid alpha(@window_fg_color, 0.8); outline-offset: 2px; }
.style-choice { padding: 6px; border-radius: 9999px; }
"""


def load_styles():
    """The styles, or None (no file): no avatar page then."""
    try:
        return json.load(open(STYLES))["styles"] or None
    except (OSError, ValueError, KeyError):
        return None


def _hex(color):
    return color if color == "transparent" else "#" + color


def render_svg(style, choice):
    """The style's body with the chosen parts (which can hold other parts)
    and colors, over the background."""
    def fill(markup, depth=0):
        def part(m):
            name = choice["parts"].get(m[1])
            return fill(style["parts"][m[1]].get(name, ""), depth + 1) if name and depth < 8 else ""
        markup = re.sub(r"%%part:(\w+)%%", part, markup)
        return re.sub(r"%%color:(\w+)%%", lambda m: _hex(choice["colors"][m[1]]), markup)
    attributes = " ".join(f"{k}={quoteattr(str(v))}" for k, v in style["attributes"].items())
    x, y, w, h = style["attributes"]["viewBox"].split()
    return (f'<svg xmlns="http://www.w3.org/2000/svg" {attributes}>'
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{_hex(choice["background"])}"/>'
            f'{fill(style["body"])}</svg>')


def render(style, choice, size=SIZE):
    """The avatar drawn by librsvg (in process: GdkPixbuf would go through
    glycin's sandboxed loaders, one process per picture)."""
    handle = Rsvg.Handle.new_from_data(render_svg(style, choice).encode())
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    viewport = Rsvg.Rectangle()
    viewport.x, viewport.y, viewport.width, viewport.height = 0, 0, size, size
    handle.render_document(cairo.Context(surface), viewport)
    surface.flush()
    return surface


def png(surface):
    out = io.BytesIO()
    surface.write_to_png(out)
    return out.getvalue()


def texture(surface):
    return Gdk.MemoryTexture.new(surface.get_width(), surface.get_height(),
                                 Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED,
                                 GLib.Bytes.new(bytes(surface.get_data())), surface.get_stride())


def show(avatar, texture):
    """The picture on an Adw.Avatar, or its initials. libadwaita sizes the
    initials when the name is set: set while a picture was showing, they
    come back tiny, so the name is set again."""
    avatar.set_custom_image(texture)
    if texture is None:
        name = avatar.get_text() or ""
        avatar.set_text("")
        avatar.set_text(name)


def backgrounds(style):
    return style["backgrounds"] or BACKGROUNDS


def random_choice(style):
    parts = {}
    for group, names in style["choices"].items():
        chance = style["probability"].get(group, 100)
        parts[group] = random.choice(names) if random.random() * 100 < chance else None
    return {"style": style["id"], "parts": parts,
            "colors": {c: random.choice(p) for c, p in style["colors"].items()},
            "background": random.choice(backgrounds(style))}


class AvatarEditor(Gtk.Box):
    """Preview, style, parts and colors. `png` is the picture (None with the
    switch off); "changed" is emitted whenever it changes."""

    __gsignals__ = {"changed": (GObject.SignalFlags.RUN_FIRST, None, ())}

    def __init__(self, styles, t):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=24)
        self.styles = {s["id"]: s for s in styles}
        self.t = t
        self.png = self.texture = None
        self._syncing = False
        colors = {c for s in styles for p in list(s["colors"].values()) + [backgrounds(s)]
                  for c in p if re.fullmatch(r"[0-9a-f]{6}", c)}
        provider = Gtk.CssProvider()
        provider.load_from_string(CSS + "".join(f".swatch-{c} {{ background: #{c}; }}\n"
                                                for c in colors))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self.preview = Adw.Avatar(size=160, show_initials=True, halign=Gtk.Align.CENTER)
        self.shuffle = Gtk.Button(halign=Gtk.Align.CENTER)
        self.shuffle.add_css_class("pill")
        self.shuffle.connect("clicked", lambda *_: self.randomize())
        self.use = Adw.SwitchRow(active=True)
        self.use.connect("notify::active", lambda *_: self._render())
        use_group = Adw.PreferencesGroup()
        use_group.add(self.use)

        # The styles, each shown by a random avatar of its own
        self.style_group = Adw.PreferencesGroup()
        flow = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, max_children_per_line=6,
                           min_children_per_line=3, column_spacing=12, row_spacing=12,
                           halign=Gtk.Align.CENTER, margin_top=6)
        self.style_buttons, first = {}, None
        for style in styles:
            sample = Adw.Avatar(size=56, custom_image=texture(
                render(style, random_choice(style), 112)))
            button = Gtk.ToggleButton(child=sample, tooltip_text=style["title"])
            button.add_css_class("flat")
            button.add_css_class("style-choice")
            if first:
                button.set_group(first)
            first = first or button
            button.connect("toggled", lambda b, s=style["id"]:
                           b.get_active() and not self._syncing and self.randomize(s))
            flow.append(button)
            self.style_buttons[style["id"]] = button
        self.style_group.add(flow)
        self.credits = Gtk.Label(wrap=True, justify=Gtk.Justification.CENTER, margin_top=12)
        self.credits.add_css_class("dim-label")
        self.credits.add_css_class("caption")
        self.style_group.add(self.credits)

        # Parts and colors: rebuilt for each style
        self.details = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
        self.use.bind_property("active", self.style_group, "sensitive",
                               GObject.BindingFlags.SYNC_CREATE)
        self.use.bind_property("active", self.details, "sensitive",
                               GObject.BindingFlags.SYNC_CREATE)

        for widget in (self.preview, self.shuffle, use_group, self.style_group, self.details):
            self.append(widget)
        self.randomize(styles[0]["id"])

    # --- labels ----------------------------------------------------------------

    def _label(self, kind, key):
        try:
            return self.t(LABELS.get((self.style["id"], key)) or f"{kind}_{key}")
        except KeyError:  # a part without a translation: its name, readable
            return re.sub(r"(?<!^)([A-Z])", r" \1", key).capitalize()

    def retranslate(self):
        self.shuffle.set_child(Adw.ButtonContent(icon_name="media-playlist-shuffle-symbolic",
                                                 label=self.t("random")))
        self.use.set_title(self.t("use_picture"))
        self.use.set_subtitle(self.t("use_picture_body"))
        self.style_group.set_title(self.t("avatar_style"))
        self._build_details()

    def set_name(self, name):
        self.preview.set_text(name)

    # --- choices ---------------------------------------------------------------

    def randomize(self, style_id=None):
        self.style = self.styles[style_id or self.choice["style"]]
        self.choice = random_choice(self.style)
        self._syncing = True
        self.style_buttons[self.style["id"]].set_active(True)
        self._syncing = False
        self.credits.set_label(f"{self.style['title']} — {self.style['creator']} · "
                               f"{self.style['license']} · DiceBear")
        self._build_details()
        self._render()

    def _options(self, group):
        names = self.style["choices"][group]
        return ([None] if group in self.style["probability"] else []) + names

    def _step(self, group, step):
        options = self._options(group)
        current = self.choice["parts"][group]
        self.choice["parts"][group] = options[(options.index(current) + step) % len(options)]
        self._render()

    def _set_color(self, name, color):
        if name == "background":
            self.choice["background"] = color
        else:
            self.choice["colors"][name] = color
        self._render()

    def _build_details(self):
        while child := self.details.get_first_child():
            self.details.remove(child)
        self.part_rows = {}
        parts = Adw.PreferencesGroup(title=self.t("features"))
        for group in self.style["choices"]:
            if len(self._options(group)) < 2:
                continue
            row = Adw.ActionRow(title=self._label("part", group))
            for icon, step, tip in (("go-previous-symbolic", -1, "previous"),
                                    ("go-next-symbolic", 1, "next")):
                button = Gtk.Button(icon_name=icon, valign=Gtk.Align.CENTER,
                                    tooltip_text=self.t(tip))
                button.add_css_class("flat")
                button.add_css_class("circular")
                button.connect("clicked", lambda _, g=group, s=step: self._step(g, s))
                row.add_suffix(button)
            parts.add(row)
            self.part_rows[group] = row
        colors = Adw.PreferencesGroup(title=self.t("colors"))
        palettes = [(name, p) for name, p in self.style["colors"].items() if len(p) > 1]
        for name, palette in palettes + [("background", backgrounds(self.style))]:
            current = self.choice["background"] if name == "background" \
                else self.choice["colors"][name]
            row = Adw.ActionRow(title=self._label("color", name))
            row.add_suffix(self._swatches(palette, current, name))
            colors.add(row)
        if self.part_rows:
            self.details.append(parts)
        self.details.append(colors)
        self._part_labels()

    def _swatches(self, palette, current, name):
        box = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
        first = None
        for color in palette:
            button = Gtk.ToggleButton(active=color == current, valign=Gtk.Align.CENTER)
            button.add_css_class("swatch")
            button.add_css_class(f"swatch-{color}")
            if first:
                button.set_group(first)
            first = first or button
            button.connect("toggled", lambda b, c=color: b.get_active() and self._set_color(name, c))
            box.append(button)
        return box

    def _part_labels(self):
        for group, row in self.part_rows.items():
            names, value = self.style["choices"][group], self.choice["parts"][group]
            row.set_subtitle(f"{names.index(value) + 1} / {len(names)}" if value
                             else self.t("none"))

    def _render(self):
        self._part_labels()
        if self.use.get_active():
            surface = render(self.style, self.choice)
            self.png, self.texture = png(surface), texture(surface)
        else:
            self.png = self.texture = None
        show(self.preview, self.texture)
        self.emit("changed")

    @property
    def title(self):
        return self.style["title"]

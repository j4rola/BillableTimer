"""Shared GTK building blocks (the Swift `RootView` shared components)."""

from __future__ import annotations

from datetime import datetime, time
from typing import Callable, Iterable, Optional

from gi.repository import Adw, GLib, Gtk, Pango

from .core import PERIOD_KINDS, Entry, fmt_clock, fmt_duration
from .model import AppModel


def label(text: str = "", *classes: str, xalign: float = 0.0, width: int = -1,
          ellipsize: bool = False, wrap: bool = False, hexpand: bool = False) -> Gtk.Label:
    widget = Gtk.Label(label=text, xalign=xalign, css_classes=list(classes), hexpand=hexpand)
    widget.set_use_markup(False)
    if width > 0:
        widget.set_size_request(width, -1)
    if ellipsize:
        widget.set_ellipsize(Pango.EllipsizeMode.END)
    if wrap:
        widget.set_wrap(True)
        widget.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
    return widget


def hbox(spacing: int = 12, **kwargs) -> Gtk.Box:
    return Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=spacing, **kwargs)


def vbox(spacing: int = 0, **kwargs) -> Gtk.Box:
    return Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing, **kwargs)


def clear(box: Gtk.Box) -> None:
    while (child := box.get_first_child()) is not None:
        box.remove(child)


def section_title(text: str) -> Gtk.Label:
    return label(text, "section-title")


def divider() -> Gtk.Separator:
    return Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)


def dot() -> Gtk.Box:
    return Gtk.Box(css_classes=["running-dot"], valign=Gtk.Align.CENTER, halign=Gtk.Align.CENTER)


def stat_tile(caption: str, value: str, accent: bool = False) -> Gtk.Box:
    box = vbox(3, css_classes=["stat-tile"], hexpand=True)
    box.set_homogeneous(False)
    box.append(label(caption.upper(), "stat-caption"))
    value_label = label(value, "stat-value", "numeric", ellipsize=True)
    if accent:
        value_label.add_css_class("success")
    box.append(value_label)
    return box


def stat_row(tiles: Iterable[tuple]) -> Gtk.Box:
    row = hbox(12, homogeneous=True)
    for tile in tiles:
        row.append(stat_tile(*tile))
    return row


def empty_hint(icon: str, title: str, message: str) -> Adw.StatusPage:
    page = Adw.StatusPage(icon_name=icon, title=GLib.markup_escape_text(title),
                          description=GLib.markup_escape_text(message), vexpand=True)
    page.add_css_class("compact")
    return page


def action_menu(items: list) -> Gtk.MenuButton:
    """A "⋯" menu. `items` holds (label, callback, enabled, destructive), or None
    for a divider. Plain buttons rather than a GMenu, since each row of a list
    would otherwise need its own action group."""
    popover = Gtk.Popover(has_arrow=True)
    content = vbox(2)
    popover.set_child(content)

    for item in items:
        if item is None:
            content.append(divider())
            continue
        text, callback, enabled, destructive = item
        button = Gtk.Button(sensitive=enabled, css_classes=["flat"])
        button.set_child(label(text))
        if destructive:
            button.add_css_class("error")

        def clicked(_button, run=callback):
            popover.popdown()
            run()

        button.connect("clicked", clicked)
        content.append(button)

    return Gtk.MenuButton(icon_name="view-more-symbolic", popover=popover,
                          css_classes=["flat"], valign=Gtk.Align.CENTER)


def select_all_on_focus(widget: Gtk.Widget) -> Gtk.Widget:
    """Selects a field's whole value when it gains focus (click or Tab), so a
    number can be retyped without first clearing it. Deferred to idle so it
    runs after GTK places the cursor for the click itself."""
    def select(*_args) -> bool:
        if widget.has_focus() or widget.get_focus_child() is not None:
            widget.select_region(0, -1)
        return GLib.SOURCE_REMOVE

    focus = Gtk.EventControllerFocus()
    focus.connect("enter", lambda _c: GLib.idle_add(select))
    widget.add_controller(focus)
    return widget


def icon_label_button(icon: str, text: str, *classes: str) -> Gtk.Button:
    button = Gtk.Button(css_classes=list(classes))
    button.set_child(Adw.ButtonContent(icon_name=icon, label=text))
    return button


class DateTimeButton(Gtk.MenuButton):
    """Calendar popover, with hour and minute spinners unless `with_time` is off."""

    def __init__(self, value: datetime, with_time: bool = True,
                 on_change: Optional[Callable[[], None]] = None):
        super().__init__(valign=Gtk.Align.CENTER)
        self.with_time = with_time
        self.on_change = on_change
        self._loading = False
        self._value = value.replace(microsecond=0)

        self.calendar = Gtk.Calendar()
        self.calendar.connect("day-selected", self._picked)
        box = vbox(8)
        box.append(self.calendar)
        if with_time:
            self.hour = Gtk.SpinButton.new_with_range(1, 12, 1)
            self.minute = Gtk.SpinButton.new_with_range(0, 59, 1)
            for spin in (self.hour, self.minute):
                spin.set_wrap(True)
                spin.set_numeric(True)
                spin.connect("value-changed", self._picked)
                select_all_on_focus(spin)
            self.minute.connect("output", self._pad_minutes)
            self.am = Gtk.ToggleButton(label="AM")
            self.pm = Gtk.ToggleButton(label="PM", group=self.am)
            for toggle in (self.am, self.pm):
                toggle.connect("toggled", self._meridiem_toggled)
            meridiem = hbox(0, css_classes=["linked"], valign=Gtk.Align.CENTER)
            meridiem.append(self.am)
            meridiem.append(self.pm)
            row = hbox(6, halign=Gtk.Align.CENTER)
            row.append(self.hour)
            row.append(label(":"))
            row.append(self.minute)
            row.append(meridiem)
            box.append(row)
        popover = Gtk.Popover()
        popover.set_child(box)
        self.set_popover(popover)
        self._load()

    @staticmethod
    def _pad_minutes(spin: Gtk.SpinButton) -> bool:
        spin.set_text(f"{int(spin.get_value()):02d}")
        return True

    def _meridiem_toggled(self, toggle: Gtk.ToggleButton) -> None:
        # Both buttons fire on a switch; only react to the one turning on.
        if toggle.get_active():
            self._picked()

    def _load(self) -> None:
        self._loading = True
        value = self._value
        self.calendar.select_day(GLib.DateTime.new_local(value.year, value.month, value.day, 12, 0, 0))
        if self.with_time:
            self.hour.set_value(value.hour % 12 or 12)
            self.minute.set_value(value.minute)
            (self.pm if value.hour >= 12 else self.am).set_active(True)
        self._loading = False
        self._show()

    def _show(self) -> None:
        pattern = "%b %-d, %Y · %-I:%M %p" if self.with_time else "%b %-d, %Y"
        self.set_label(self._value.strftime(pattern))

    def _picked(self, *_args) -> None:
        if self._loading:
            return
        picked = self.calendar.get_date()
        self._value = self._value.replace(year=picked.get_year(), month=picked.get_month(),
                                          day=picked.get_day_of_month())
        if self.with_time:
            hour = int(self.hour.get_value()) % 12 + (12 if self.pm.get_active() else 0)
            self._value = self._value.replace(hour=hour, minute=int(self.minute.get_value()))
        self._show()
        if self.on_change:
            self.on_change()

    @property
    def value(self) -> datetime:
        return self._value

    @value.setter
    def value(self, value: datetime) -> None:
        self._value = value.replace(microsecond=0)
        self._load()

    @property
    def day(self) -> datetime:
        return datetime.combine(self._value.date(), time.min)


class TextRow(Adw.PreferencesRow):
    """A captioned multi-line text field; `Adw.EntryRow` is single-line only."""

    def __init__(self, title: str, text: str = "", on_change: Optional[Callable[[str], None]] = None):
        super().__init__(activatable=False, focusable=False)
        box = vbox(4, margin_top=8, margin_bottom=8, margin_start=12, margin_end=12)
        box.append(label(title, "caption", "dim-label"))
        self.view = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR, accepts_tab=False,
                                 top_margin=2, bottom_margin=2, css_classes=["text-row"])
        self.view.set_size_request(-1, 54)
        self.view.get_buffer().set_text(text)
        if on_change:
            self.view.get_buffer().connect("changed", lambda _b: on_change(self.text))
        box.append(self.view)
        self.set_child(box)

    @property
    def text(self) -> str:
        return self.view.get_buffer().props.text

    @text.setter
    def text(self, value: str) -> None:
        self.view.get_buffer().set_text(value)


class EditorDialog(Adw.Dialog):
    """A form sheet with Cancel and a primary action, shared by every editor."""

    def __init__(self, title: str, action: str, width: int = 470):
        super().__init__(title=title, content_width=width)
        self.save_button = Gtk.Button(label=action, css_classes=["suggested-action"])
        self.save_button.connect("clicked", lambda _b: self.on_save())
        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda _b: self.close())

        header = Adw.HeaderBar(show_start_title_buttons=False, show_end_title_buttons=False)
        header.pack_start(cancel)
        header.pack_end(self.save_button)
        self.set_default_widget(self.save_button)

        self.group = Adw.PreferencesGroup()
        self.body = vbox(10, margin_top=12, margin_bottom=18, margin_start=18, margin_end=18)
        self.body.append(self.group)
        scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER,
                                      propagate_natural_height=True, child=self.body)
        toolbar = Adw.ToolbarView(content=scroller)
        toolbar.add_top_bar(header)
        self.set_child(toolbar)

    def on_save(self) -> None:
        raise NotImplementedError


class Page(Gtk.Box):
    """A detail pane: title row, then content. Live readouts register here, so a
    tick updates a few labels and rebuilds nothing."""

    def __init__(self, model: AppModel, title: str, subtitle: str):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.model = model
        self.live: list[tuple[Gtk.Label, Callable[[], str]]] = []

        self.trailing = hbox(8, valign=Gtk.Align.CENTER)
        header = hbox(12, margin_top=18, margin_bottom=12, margin_start=20, margin_end=20)
        titles = vbox(2, hexpand=True)
        titles.append(label(title, "title-2"))
        titles.append(label(subtitle, "dim-label", wrap=True))
        header.append(titles)
        header.append(self.trailing)
        self.append(header)

    def live_label(self, entries: list[Entry], compact: bool, *classes: str, xalign: float = 1.0) -> Gtk.Label:
        def text() -> str:
            seconds = sum(e.seconds(self.model.now) for e in entries)
            return fmt_duration(seconds) if compact else fmt_clock(seconds)

        widget = label(text(), "numeric", *classes, xalign=xalign)
        self.live.append((widget, text))
        return widget

    def tick(self) -> None:
        for widget, text in self.live:
            widget.set_text(text())

    def refresh(self) -> None:
        """Rebuilds from the model. Only ever called on the visible page."""

    def coarse(self) -> None:
        """The 15-second tick, for pages with running totals."""

    def on_enter(self) -> None:
        self.refresh()

    def on_leave(self) -> None:
        pass


def scrolled(child: Gtk.Widget) -> Gtk.ScrolledWindow:
    return Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, vexpand=True, child=child)


class PeriodBar(Gtk.Box):
    """‹ Today › navigation shared by Entries and Reports."""

    def __init__(self, model: AppModel):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=12,
                         margin_start=20, margin_end=20, margin_bottom=10)
        self.model = model
        self.kinds: dict[str, Gtk.ToggleButton] = {}
        linked = hbox(0, css_classes=["linked"], hexpand=True, halign=Gtk.Align.START)
        for kind in PERIOD_KINDS:
            button = Gtk.ToggleButton(label=kind)
            if self.kinds:
                button.set_group(next(iter(self.kinds.values())))
            button.connect("toggled", self._kind_toggled, kind)
            self.kinds[kind] = button
            linked.append(button)
        self.append(linked)

        previous = Gtk.Button(icon_name="go-previous-symbolic", css_classes=["flat"])
        previous.connect("clicked", lambda _b: model.shift_period(-1))
        following = Gtk.Button(icon_name="go-next-symbolic", css_classes=["flat"])
        following.connect("clicked", lambda _b: model.shift_period(1))
        self.range_label = label("", "heading", xalign=0.5, width=190)
        self.today = Gtk.Button(label="Today")
        self.today.connect("clicked", lambda _b: model.jump_to_today())
        for widget in (previous, self.range_label, following, self.today):
            self.append(widget)
        self._syncing = False

    def _kind_toggled(self, button: Gtk.ToggleButton, kind: str) -> None:
        if button.get_active() and not self._syncing and self.model.period_kind != kind:
            self.model.set_period_kind(kind)

    def refresh(self) -> None:
        self._syncing = True
        self.kinds[self.model.period_kind].set_active(True)
        self._syncing = False
        self.range_label.set_text(self.model.range_label)
        self.today.set_sensitive(not self.model.is_current_period)

"""Application entry point, main window, and styling."""

from __future__ import annotations

import locale
import sys
from typing import Optional

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402

from .core import DBError, fmt_clock  # noqa: E402
from .model import CHANGED, COARSE, ERROR, TICK, AppModel  # noqa: E402
from .pages import (  # noqa: E402
    ClientsPage, EntriesPage, InvoicesPage, ReportsPage, SettingsPage, TimersPage,
)
from .tray import Tray  # noqa: E402
from .widgets import dot, hbox, label, vbox  # noqa: E402

APP_ID = "io.github.j4rola.BillableTimer"

CSS = """
.section-title { font-size: 0.85em; font-weight: 600; opacity: 0.65; }
.stat-tile { padding: 12px 14px; border-radius: 10px; background: alpha(currentColor, 0.06); }
.stat-caption { font-size: 0.72em; font-weight: 600; letter-spacing: 0.06em; opacity: 0.65; }
.stat-value { font-size: 1.6em; font-weight: 600; }
.running-card { padding: 14px; border-radius: 12px; background: alpha(currentColor, 0.05);
                border: 1px solid alpha(@destructive_color, 0.3); }
.live-clock { font-size: 1.5em; font-weight: 600; }
.project-tile { padding: 12px; border-radius: 10px; background: alpha(currentColor, 0.05); }
.running-dot { min-width: 8px; min-height: 8px; border-radius: 50%; background: @destructive_color; }
.badge { font-size: 0.7em; font-weight: 700; padding: 1px 5px; border-radius: 99px; }
.badge-running { color: @destructive_color; background: alpha(@destructive_color, 0.18); }
.badge-invoiced { color: @success_color; background: alpha(@success_color, 0.18); }
.text-row, .text-row text { background: transparent; }
"""


class MainWindow(Adw.ApplicationWindow):
    SECTIONS = (
        ("Timers", "alarm-symbolic", TimersPage),
        ("Entries", "view-list-symbolic", EntriesPage),
        ("Reports", "x-office-spreadsheet-symbolic", ReportsPage),
        ("Clients & Projects", "system-users-symbolic", ClientsPage),
        ("Invoices", "x-office-document-symbolic", InvoicesPage),
        ("Settings", "emblem-system-symbolic", SettingsPage),
    )

    def __init__(self, app: Adw.Application, model: AppModel):
        super().__init__(application=app, title="BillableTimer", default_width=1080, default_height=700,
                         width_request=360, height_request=200)
        self.model = model
        self.pages = []
        self.current = None

        self.stack = Gtk.Stack(vexpand=True, hexpand=True,
                               transition_type=Gtk.StackTransitionType.NONE)
        self.sidebar = Gtk.ListBox(css_classes=["navigation-sidebar"], vexpand=True)
        for title, icon, page_class in self.SECTIONS:
            page = page_class(model)
            self.pages.append(page)
            # Tiling compositors ignore minimum sizes and may hand us a small tile,
            # so an oversized page scrolls instead of being clipped.
            self.stack.add_child(Gtk.ScrolledWindow(child=page))
            row = hbox(10, margin_top=4, margin_bottom=4, margin_start=4)
            row.append(Gtk.Image(icon_name=icon))
            row.append(label(title))
            self.sidebar.append(row)
        self.sidebar.connect("row-selected", self._section_selected)
        self.sidebar.connect("row-activated", lambda *_a: self.split.set_show_content(True))

        self.running_count = label("", "caption", hexpand=True)
        self.running_total = label("", "caption", "numeric", xalign=1)
        self.footer = hbox(8, margin_start=12, margin_end=12, margin_top=8, margin_bottom=10)
        for widget in (dot(), self.running_count, self.running_total):
            self.footer.append(widget)

        side = vbox()
        side.append(self.sidebar)
        side.append(self.footer)
        side_view = Adw.ToolbarView(content=side)
        side_view.add_top_bar(Adw.HeaderBar(show_title=True))
        sidebar_page = Adw.NavigationPage(title="BillableTimer", child=side_view)

        self.banner = Adw.Banner(button_label="Dismiss", use_markup=False)
        self.banner.connect("button-clicked", lambda _b: model.set_error(None))
        content = Adw.ToolbarView(content=self.stack)
        header = Adw.HeaderBar(show_title=False)
        content.add_top_bar(header)
        content.add_top_bar(self.banner)
        content_page = Adw.NavigationPage(title="BillableTimer", child=content)

        self.split = Adw.NavigationSplitView(sidebar=sidebar_page, content=content_page,
                                             min_sidebar_width=190, max_sidebar_width=240,
                                             show_content=True)
        self.set_content(self.split)
        narrow = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 640sp"))
        narrow.add_setter(self.split, "collapsed", True)
        self.add_breakpoint(narrow)

        model.subscribe(CHANGED, self._on_changed)
        model.subscribe(TICK, self._on_tick)
        model.subscribe(COARSE, self._on_coarse)
        model.subscribe(ERROR, self._on_error)

        stop_all = Gio.SimpleAction.new("stop-all", None)
        stop_all.connect("activate", lambda *_a: model.stop_all())
        self.add_action(stop_all)
        app.set_accels_for_action("win.stop-all", ["<Control><Shift>period"])

        self.connect("close-request", self._on_close)
        self.sidebar.select_row(self.sidebar.get_row_at_index(0))
        self._update_footer()

    def _section_selected(self, _list, row: Optional[Gtk.ListBoxRow]) -> None:
        if row is None:
            return
        page = self.pages[row.get_index()]
        if self.current is page:
            return
        if self.current is not None:
            self.current.on_leave()
        self.current = page
        self.stack.set_visible_child(page.get_parent().get_parent())
        page.on_enter()

    def _update_footer(self) -> None:
        count = len(self.model.running)
        self.footer.set_visible(count > 0)
        self.running_count.set_text(f"{count} running")
        self.running_total.set_text(fmt_clock(self.model.running_seconds()))

    def _on_changed(self) -> None:
        self._update_footer()
        if self.current is not None and self.get_visible():
            self.current.refresh()

    def _on_tick(self) -> None:
        self._update_footer()
        if self.current is not None and self.get_visible():
            self.current.tick()

    def _on_coarse(self) -> None:
        if self.current is not None and self.get_visible():
            self.current.coarse()

    def _on_error(self) -> None:
        message = self.model.error_message
        if message:
            self.banner.set_title(message)
        self.banner.set_revealed(bool(message))

    def show_main(self) -> None:
        if self.current is not None:
            self.model.reload_all()  # the window ignored changes while it was hidden
        self.set_visible(True)
        self.present()

    def _on_close(self, _window) -> bool:
        if self.current is not None:
            self.current.on_leave()
        self.model.commit_notes()
        app = self.get_application()
        if app.tray is not None and app.tray.registered:
            self.set_visible(False)  # stays reachable from the tray, like the macOS app
            return True
        return False


class BillableTimerApp(Adw.Application):
    def __init__(self) -> None:
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.window: Optional[MainWindow] = None
        self.tray: Optional[Tray] = None

    def do_activate(self) -> None:
        if self.window is not None:
            self.window.show_main()
            return

        provider = Gtk.CssProvider()
        provider.load_from_string(CSS)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        try:
            model = AppModel()
        except DBError as error:
            # The database is the whole app; say so plainly rather than half-run.
            self._fatal(str(error))
            return

        self.window = MainWindow(self, model)
        try:
            self.tray = Tray(model, self.window.show_main, self._quit)
        except GLib.Error:
            self.tray = None  # no session bus: the window still works on its own
        self.window.present()

    def _quit(self) -> None:
        if self.window is not None:
            if self.window.current is not None:
                self.window.current.on_leave()
            self.window.model.commit_notes()
        self.quit()

    def _fatal(self, message: str) -> None:
        window = Adw.ApplicationWindow(application=self, title="BillableTimer", default_width=480,
                                       default_height=300)
        status = Adw.StatusPage(icon_name="dialog-error-symbolic",
                                title="BillableTimer could not open its database",
                                description=GLib.markup_escape_text(message))
        button = Gtk.Button(label="Quit", halign=Gtk.Align.CENTER, css_classes=["pill"])
        button.connect("clicked", lambda _b: self.quit())
        status.set_child(button)
        window.set_content(status)
        window.present()


def main() -> int:
    try:
        locale.setlocale(locale.LC_ALL, "")
    except locale.Error:
        pass
    GLib.set_prgname(APP_ID)
    GLib.set_application_name("BillableTimer")
    return BillableTimerApp().run(sys.argv)

"""The status item: a StatusNotifierItem plus a com.canonical.dbusmenu menu.

The Linux counterpart of `MenuBarController`, spoken directly over D-Bus so
there is no appindicator dependency. Trays have no text slot, so the live clock
lives in the tooltip and menu; the icon gains a red dot while anything runs.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Callable

import cairo
from gi.repository import Gio, GLib

from . import core
from .model import CHANGED, COARSE, TICK, AppModel

ITEM_PATH = "/StatusNotifierItem"
MENU_PATH = "/MenuBar"
WATCHER = "org.kde.StatusNotifierWatcher"
MAX_START_ITEMS = 12

ITEM_XML = """
<node><interface name="org.kde.StatusNotifierItem">
  <property name="Category" type="s" access="read"/>
  <property name="Id" type="s" access="read"/>
  <property name="Title" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="WindowId" type="i" access="read"/>
  <property name="IconName" type="s" access="read"/>
  <property name="IconPixmap" type="a(iiay)" access="read"/>
  <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/>
  <property name="Menu" type="o" access="read"/>
  <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
  <signal name="NewTitle"/>
  <signal name="NewIcon"/>
  <signal name="NewToolTip"/>
  <signal name="NewStatus"><arg type="s"/></signal>
</interface></node>
"""

MENU_XML = """
<node><interface name="com.canonical.dbusmenu">
  <property name="Version" type="u" access="read"/>
  <property name="TextDirection" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="IconThemePath" type="as" access="read"/>
  <method name="GetLayout">
    <arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
    <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/>
  </method>
  <method name="GetGroupProperties">
    <arg type="ai" direction="in"/><arg type="as" direction="in"/>
    <arg type="a(ia{sv})" direction="out"/>
  </method>
  <method name="GetProperty">
    <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/>
  </method>
  <method name="Event">
    <arg type="i" direction="in"/><arg type="s" direction="in"/>
    <arg type="v" direction="in"/><arg type="u" direction="in"/>
  </method>
  <method name="EventGroup">
    <arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/>
  </method>
  <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
  <method name="AboutToShowGroup">
    <arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/>
  </method>
  <signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
  <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
  <signal name="ItemActivationRequested"><arg type="i"/><arg type="u"/></signal>
</interface></node>
"""


def _pixmap(running: bool) -> list:
    """The app icon as SNI ARGB32, with a red dot while timers run. An opaque
    plate rather than a symbolic glyph, so it reads on any bar theme."""
    size = 64
    source = cairo.ImageSurface.create_from_png(str(Path(__file__).with_name("icon.png")))
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    ctx = cairo.Context(surface)
    ctx.scale(size / source.get_width(), size / source.get_height())
    ctx.set_source_surface(source)
    ctx.paint()
    ctx.identity_matrix()
    if running:
        ctx.arc(47, 47, 15, 0, 6.2832)
        ctx.set_source_rgb(1, 1, 1)
        ctx.fill()
        ctx.arc(47, 47, 12, 0, 6.2832)
        ctx.set_source_rgb(0.88, 0.11, 0.14)
        ctx.fill()
    surface.flush()
    bgra = bytes(surface.get_data())  # cairo is native-endian, SNI is big-endian
    argb = bytearray(len(bgra))
    for offset in range(4):
        argb[offset::4] = bgra[3 - offset::4]
    return [(size, size, bytes(argb))]


class Tray:
    def __init__(self, model: AppModel, open_main: Callable[[], None], quit_app: Callable[[], None]):
        self.model = model
        self.open_main = open_main
        self.quit_app = quit_app
        self.registered = False
        self.revision = 1
        self.actions: dict[int, Callable[[], None]] = {}
        self.icons = {False: _pixmap(False), True: _pixmap(True)}
        self.was_running = bool(model.running)

        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.bus_name = f"org.kde.StatusNotifierItem-{os.getpid()}-1"
        self._export(ITEM_PATH, ITEM_XML, self._item_method, self._item_property)
        self._export(MENU_PATH, MENU_XML, self._menu_method, self._menu_property)
        Gio.bus_own_name_on_connection(self.bus, self.bus_name, Gio.BusNameOwnerFlags.NONE, None, None)
        # Registration is repeated each time the watcher appears, which also
        # brings the item back after the shell restarts.
        Gio.bus_watch_name_on_connection(
            self.bus, WATCHER, Gio.BusNameWatcherFlags.NONE, self._watcher_appeared, self._watcher_vanished,
        )

        model.subscribe(TICK, self._refresh_status)
        model.subscribe(CHANGED, self._on_changed)
        model.subscribe(COARSE, self._layout_updated)

    def _export(self, path, xml, method, getter) -> None:
        info = Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0]
        self.bus.register_object(path, info, method, getter, None)

    def _watcher_appeared(self, _connection, _name, _owner) -> None:
        def done(bus, result):
            try:
                bus.call_finish(result)
                self.registered = True
            except GLib.Error:
                self.registered = False

        self.bus.call(
            WATCHER, "/StatusNotifierWatcher", WATCHER, "RegisterStatusNotifierItem",
            GLib.Variant("(s)", (self.bus_name,)), None, Gio.DBusCallFlags.NONE, -1, None, done,
        )

    def _watcher_vanished(self, _connection, _name) -> None:
        self.registered = False

    def _signal(self, path, interface, name, params=None) -> None:
        self.bus.emit_signal(None, path, interface, name, params)

    # StatusNotifierItem

    def _status_text(self) -> str:
        model = self.model
        count = len(model.running)
        if count:
            return f"{core.fmt_clock(model.running_seconds())} · {count} running"
        return "BillableTimer"

    def _item_property(self, _conn, _sender, _path, _iface, name):
        running = bool(self.model.running)
        values = {
            "Category": GLib.Variant("s", "ApplicationStatus"),
            "Id": GLib.Variant("s", "BillableTimer"),
            "Title": GLib.Variant("s", "BillableTimer"),
            "Status": GLib.Variant("s", "Active"),
            "WindowId": GLib.Variant("i", 0),
            "IconName": GLib.Variant("s", ""),
            "IconPixmap": GLib.Variant("a(iiay)", self.icons[running]),
            "ToolTip": GLib.Variant("(sa(iiay)ss)", ("", [], self._status_text(), "")),
            "ItemIsMenu": GLib.Variant("b", False),
            "Menu": GLib.Variant("o", MENU_PATH),
        }
        return values.get(name)

    def _item_method(self, _conn, _sender, _path, _iface, name, _params, invocation) -> None:
        if name in ("Activate", "SecondaryActivate"):
            GLib.idle_add(self._open_once)
        invocation.return_value(None)

    def _open_once(self) -> bool:
        self.open_main()
        return GLib.SOURCE_REMOVE

    def _refresh_status(self) -> None:
        self._signal(ITEM_PATH, "org.kde.StatusNotifierItem", "NewToolTip")

    def _on_changed(self) -> None:
        running = bool(self.model.running)
        if running != self.was_running:
            self.was_running = running
            self._signal(ITEM_PATH, "org.kde.StatusNotifierItem", "NewIcon")
        self._refresh_status()
        self._layout_updated()

    # dbusmenu

    def _layout_updated(self) -> None:
        self.revision += 1
        self._signal(MENU_PATH, "com.canonical.dbusmenu", "LayoutUpdated",
                     GLib.Variant("(ui)", (self.revision, 0)))

    @staticmethod
    def _label(text: str) -> str:
        return text.replace("_", "__")  # a lone underscore marks a mnemonic

    def _items(self) -> list[tuple[int, dict]]:
        model = self.model
        items: list[tuple[int, dict]] = []
        actions: dict[int, Callable[[], None]] = {}

        def text(item_id, label, action=None):
            props = {"label": GLib.Variant("s", self._label(label))}
            if action is None:
                props["enabled"] = GLib.Variant("b", False)
            else:
                actions[item_id] = action
            items.append((item_id, props))

        def separator(item_id):
            items.append((item_id, {"type": GLib.Variant("s", "separator")}))

        now = model.now
        today = sum(e.seconds(now) for e in model.today_entries)
        text(1, f"Today: {core.fmt_duration(today)}")
        separator(2)
        if model.running:
            for entry in model.running:
                label = f"Stop {entry.project_name} ({entry.client_name}) · {core.fmt_clock(entry.seconds(now))}"
                text(1_000_000 + entry.id, label, lambda e=entry: model.stop_timer(e))
            if len(model.running) > 1:
                text(3, "Stop All", model.stop_all)
            separator(4)
        if model.projects:
            for project in model.projects[:MAX_START_ITEMS]:
                text(2_000_000 + project.id, f"Start {project.name} ({project.client_name})",
                     lambda p=project: model.start_timer(p.id))
        else:
            text(5, "Add a client and project in the main window first.")
        separator(6)
        text(7, "Open BillableTimer", self.open_main)
        text(8, "Quit", self.quit_app)
        self.actions = actions
        return items

    def _layout(self) -> GLib.Variant:
        children = [
            GLib.Variant("v", GLib.Variant("(ia{sv}av)", (item_id, props, [])))
            for item_id, props in self._items()
        ]
        root = {"children-display": GLib.Variant("s", "submenu")}
        return GLib.Variant("(u(ia{sv}av))", (self.revision, (0, root, children)))

    def _menu_property(self, _conn, _sender, _path, _iface, name):
        values = {
            "Version": GLib.Variant("u", 3),
            "TextDirection": GLib.Variant("s", "ltr"),
            "Status": GLib.Variant("s", "normal"),
            "IconThemePath": GLib.Variant("as", []),
        }
        return values.get(name)

    def _click(self, item_id: int) -> None:
        action = self.actions.get(item_id)
        if action is not None:
            def run():
                action()
                return GLib.SOURCE_REMOVE
            GLib.idle_add(run)

    def _menu_method(self, _conn, _sender, _path, _iface, name, params, invocation) -> None:
        args = params.unpack()
        if name == "GetLayout":
            invocation.return_value(self._layout())
        elif name == "GetGroupProperties":
            wanted = set(args[0])
            found = [(i, p) for i, p in self._items() if not wanted or i in wanted]
            invocation.return_value(GLib.Variant("(a(ia{sv}))", (found,)))
        elif name == "GetProperty":
            props = dict(self._items()).get(args[0], {})
            value = props.get(args[1], GLib.Variant("s", ""))
            invocation.return_value(GLib.Variant("(v)", (value,)))
        elif name == "Event":
            if args[1] == "clicked":
                self._click(args[0])
            invocation.return_value(None)
        elif name == "EventGroup":
            for item_id, event, _data, _time in args[0]:
                if event == "clicked":
                    self._click(item_id)
            invocation.return_value(GLib.Variant("(ai)", ([],)))
        elif name == "AboutToShow":
            invocation.return_value(GLib.Variant("(b)", (False,)))
        elif name == "AboutToShowGroup":
            invocation.return_value(GLib.Variant("(aiai)", ([], [])))

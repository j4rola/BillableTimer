"""Observable state, the timer engine, and report aggregation (Swift `AppModel`)."""

from __future__ import annotations

import sqlite3
from datetime import datetime, timedelta
from typing import Callable, Optional

from gi.repository import Gio, GLib

from . import core
from .core import (
    DAY, STRIDE_DAYS, AppSettings, BreakdownRow, Client, DateRange, DayTotal, Entry, Project,
    Store,
)

CHANGED = "changed"  # data changed: rebuild what's showing
TICK = "tick"        # 1 Hz while something runs: update live readouts only
COARSE = "coarse"    # every 15 s while something runs: re-aggregate totals
ERROR = "error"      # `error_message` changed

# Ticks between coarse refreshes.
COARSE_INTERVAL = 15


class AppModel:
    def __init__(self) -> None:
        self.store = Store(core.data_dir())
        self.settings: AppSettings = self.store.load_settings()

        self.clients: list[Client] = []
        self.projects: list[Project] = []
        self.running: list[Entry] = []
        self.visible_entries: list[Entry] = []
        # Tracked apart from the browsed range, so the tray and project tiles stay
        # correct while you're looking at a past period.
        self.today_entries: list[Entry] = []
        self.invoices: list = []

        self.period_kind = DAY
        self.reference_date = datetime.now()
        self.error_message: Optional[str] = None
        self.now = datetime.now()
        # Descriptions typed on running timers but not yet saved. They live here
        # rather than in the view so that stopping a timer from the tray, with the
        # window closed, still keeps what was typed.
        self.note_drafts: dict[int, str] = {}

        # What tells a midnight rollover whether to carry the view forward or
        # leave the user where they deliberately went.
        self._browsing_past = False
        self._listeners: dict[str, list[Callable[[], None]]] = {}
        self._ticker: Optional[int] = None
        self._tick_count = 0
        self._midnight_source: Optional[int] = None

        self.reload_all()
        self._schedule_midnight()
        self._observe_sleep()

    # Events

    def subscribe(self, event: str, callback: Callable[[], None]) -> None:
        self._listeners.setdefault(event, []).append(callback)

    def _emit(self, event: str) -> None:
        for callback in self._listeners.get(event, []):
            callback()

    def _perform(self, body: Callable[[], object]) -> None:
        """Surfaces any failure in the UI banner instead of crashing."""
        try:
            body()
        except (core.DBError, sqlite3.Error) as error:
            self.set_error(str(error))

    def set_error(self, message: Optional[str]) -> None:
        self.error_message = message
        self._emit(ERROR)

    # Current range

    @property
    def range(self) -> DateRange:
        return core.period_range(self.period_kind, self.reference_date, self.settings)

    @property
    def range_label(self) -> str:
        return core.fmt_range(self.range, self.period_kind)

    @property
    def is_current_period(self) -> bool:
        return self.range.contains(datetime.now())

    def shift_period(self, steps: int) -> None:
        self.reference_date += timedelta(days=steps * STRIDE_DAYS[self.period_kind])
        self._browsing_past = not self.is_current_period
        self.reload_entries()

    def set_period_kind(self, kind: str) -> None:
        self.period_kind = kind
        self.reload_entries()

    def jump_to_today(self) -> None:
        self.reference_date = datetime.now()
        self._browsing_past = False
        self.reload_entries()

    def show_today(self) -> None:
        """Reports opens on this, so it always answers "how am I doing today"."""
        self.period_kind = DAY
        self.jump_to_today()

    def _roll_over_if_needed(self) -> None:
        if not self._browsing_past and not self.is_current_period:
            self.reference_date = datetime.now()
        self.reload_entries()

    def _schedule_midnight(self) -> None:
        """Carries an overnight session onto the new day (`NSCalendarDayChanged`)."""
        if self._midnight_source is not None:
            GLib.source_remove(self._midnight_source)
        now = datetime.now()
        seconds = int((core.day_range(now).end - now).total_seconds()) + 1

        def fire() -> bool:
            self._midnight_source = None
            self._roll_over_if_needed()
            self._schedule_midnight()
            return GLib.SOURCE_REMOVE

        self._midnight_source = GLib.timeout_add_seconds(seconds, fire)

    def _observe_sleep(self) -> None:
        """Wake handling. GLib timers pause through suspend, so a machine that
        sleeps past midnight would otherwise miss the rollover above.

        This must stay a `DBusProxy`. Holding a Python wrapper on the system
        `GDBusConnection` directly makes it that object's only owner, so each
        transient ref the GDBus worker thread takes fires a toggle notification
        that needs the GIL. Any sync D-Bus call made while the GIL is held, such
        as GTK's accessibility bus lookup during window construction, then
        deadlocks against the worker until it times out 25 seconds later.
        """

        def on_signal(_proxy, _sender, signal, params):
            if signal == "PrepareForSleep" and not params.unpack()[0]:
                self.now = datetime.now()
                self.reload_running()
                self._roll_over_if_needed()
                self._schedule_midnight()

        def ready(_source, result):
            try:
                self._login_manager = Gio.DBusProxy.new_for_bus_finish(result)
            except GLib.Error:
                return  # no logind: the rollover still fires on the next timer or reload
            self._login_manager.connect("g-signal", on_signal)

        Gio.DBusProxy.new_for_bus(
            Gio.BusType.SYSTEM,
            Gio.DBusProxyFlags.DO_NOT_LOAD_PROPERTIES | Gio.DBusProxyFlags.DO_NOT_AUTO_START,
            None, "org.freedesktop.login1", "/org/freedesktop/login1",
            "org.freedesktop.login1.Manager", None, ready,
        )

    # Loading

    def reload_all(self) -> None:
        def load():
            self.clients = self.store.clients()
            self.projects = self.store.projects()
            self.invoices = self.store.invoices()
        self._perform(load)
        self.reload_running()
        self.reload_entries()

    def reload_entries(self) -> None:
        def load():
            self.visible_entries = self.store.entries(self.range)
            self.today_entries = self.store.entries(core.day_range(datetime.now()))
        self._perform(load)
        self.now = datetime.now()
        self._tick_count = 0
        self._emit(CHANGED)

    def reload_running(self) -> None:
        def load():
            self.running = self.store.running_entries()
        self._perform(load)
        self._sync_ticker()

    def today_entries_for(self, project_id: int) -> list[Entry]:
        return [e for e in self.today_entries if e.project_id == project_id]

    def projects_for(self, client_id: int) -> list[Project]:
        return [p for p in self.projects if p.client_id == client_id]

    # Ticking

    def _sync_ticker(self) -> None:
        """The ticker exists only while something runs, so idle does no periodic
        work at all. `timeout_add_seconds` lets GLib coalesce the wakeups."""
        if not self.running:
            if self._ticker is not None:
                GLib.source_remove(self._ticker)
                self._ticker = None
            self._tick_count = 0
        elif self._ticker is None:
            self._ticker = GLib.timeout_add_seconds(1, self._on_tick)

    def _on_tick(self) -> bool:
        self.now = datetime.now()
        self._emit(TICK)
        self._tick_count += 1
        if self._tick_count >= COARSE_INTERVAL:
            self._tick_count = 0
            self._emit(COARSE)
        return GLib.SOURCE_CONTINUE

    # Timer actions

    def _after_timer_change(self) -> None:
        self.reload_running()
        self.reload_entries()

    def start_timer(self, project_id: int, note: str = "") -> None:
        self._perform(lambda: self.store.start_timer(project_id, note))
        self._after_timer_change()

    def _commit_draft(self, entry: Entry) -> None:
        draft = self.note_drafts.pop(entry.id, None)
        if draft is not None and draft != entry.note:
            self.store.update_entry(entry.id, entry.project_id, entry.started_at, None, draft)

    def commit_notes(self) -> None:
        """Saves in-progress descriptions without stopping any clock."""
        def commit():
            for entry in self.running:
                self._commit_draft(entry)
        had_drafts = bool(self.note_drafts)
        self._perform(commit)
        if had_drafts:
            self._after_timer_change()

    def stop_timer(self, entry: Entry) -> None:
        def stop():
            self._commit_draft(entry)
            self.store.stop_timer(entry.id)
        self._perform(stop)
        self._after_timer_change()

    def stop_all(self) -> None:
        def stop():
            for entry in self.running:
                self._commit_draft(entry)
            self.store.stop_all_timers()
        self._perform(stop)
        self._after_timer_change()

    def cancel_timer(self, entry: Entry) -> None:
        self.note_drafts.pop(entry.id, None)
        self._perform(lambda: self.store.cancel_timer(entry.id))
        self._after_timer_change()

    def is_running(self, project_id: int) -> bool:
        return any(e.project_id == project_id for e in self.running)

    def running_seconds(self) -> int:
        return sum(e.seconds(self.now) for e in self.running)

    # Entry actions

    def add_manual_entry(self, project_id: int, start: datetime, end: datetime, note: str) -> None:
        self._perform(lambda: self.store.add_manual_entry(project_id, start, end, note))
        self.reload_entries()

    def update_entry(self, entry_id: int, project_id: int, start: datetime,
                     end: Optional[datetime], note: str) -> None:
        self.note_drafts.pop(entry_id, None)  # the editor's text wins over a stale draft
        self._perform(lambda: self.store.update_entry(entry_id, project_id, start, end, note))
        self._after_timer_change()

    def delete_entry(self, entry: Entry) -> None:
        self._perform(lambda: self.store.delete_entry(entry.id))
        self._after_timer_change()

    # Client & project actions

    def create_client(self, name: str, rate_cents: int, address: str, notes: str) -> None:
        self._perform(lambda: self.store.create_client(name, rate_cents, address, notes))
        self.reload_all()

    def update_client(self, client: Client) -> None:
        self._perform(lambda: self.store.update_client(client))
        self.reload_all()

    def delete_client(self, client: Client) -> None:
        self._perform(lambda: self.store.delete_client(client.id))
        self.reload_all()

    def create_project(self, client_id: int, name: str, rate_cents: Optional[int]) -> None:
        self._perform(lambda: self.store.create_project(client_id, name, rate_cents))
        self.reload_all()

    def update_project(self, project: Project) -> None:
        self._perform(lambda: self.store.update_project(project))
        self.reload_all()

    def delete_project(self, project: Project) -> None:
        self._perform(lambda: self.store.delete_project(project.id))
        self.reload_all()

    # Settings

    def save_settings(self) -> None:
        self._perform(lambda: self.store.save_settings(self.settings))
        self.reload_entries()

    # Reporting

    @property
    def project_breakdown(self) -> list[BreakdownRow]:
        rows: dict[int, BreakdownRow] = {}
        for entry in self.visible_entries:
            seconds = entry.seconds(self.now)
            if entry.project_id in rows:
                rows[entry.project_id].seconds += seconds
            else:
                rows[entry.project_id] = BreakdownRow(
                    entry.client_id, entry.client_name, entry.project_id,
                    entry.project_name, seconds, entry.rate_cents,
                )
        return sorted(rows.values(), key=lambda r: (r.client_name, r.project_name or ""))

    @property
    def client_breakdown(self) -> list[tuple[BreakdownRow, int]]:
        """Amounts are summed from project rows, since projects can carry their own
        rates; recomputing from one rate would be wrong."""
        totals: dict[int, list] = {}
        for row in self.project_breakdown:
            item = totals.setdefault(row.client_id, [row.client_name, 0, 0])
            item[1] += row.seconds
            item[2] += row.amount_cents
        result = [
            (BreakdownRow(cid, name, None, None, seconds, 0), amount)
            for cid, (name, seconds, amount) in totals.items()
        ]
        return sorted(result, key=lambda pair: pair[0].client_name)

    @property
    def total_seconds(self) -> int:
        return sum(e.seconds(self.now) for e in self.visible_entries)

    @property
    def total_amount_cents(self) -> int:
        return sum(r.amount_cents for r in self.project_breakdown)

    @property
    def day_totals(self) -> list[DayTotal]:
        """Includes empty days, so the chart keeps a stable shape."""
        buckets: dict[datetime, int] = {}
        for entry in self.visible_entries:
            day = core.day_range(entry.started_at).start
            buckets[day] = buckets.get(day, 0) + entry.seconds(self.now)
        return [DayTotal(day, buckets.get(day, 0)) for day in core.days_in(self.range)]

"""The six detail panes (the Swift `Views/` directory)."""

from __future__ import annotations

import math
import os
from datetime import datetime, timedelta
from typing import Optional

import gi
from gi.repository import Adw, Gio, GLib, Gtk, Pango, PangoCairo

from . import core, invoice_pdf
from .core import Client, Entry, Project, fmt_duration, fmt_hours, fmt_money
from .model import AppModel
from .widgets import (
    DateTimeButton, EditorDialog, Page, PeriodBar, TextRow, action_menu, clear, divider, dot,
    empty_hint, hbox, icon_label_button, label, scrolled, section_title, stat_row, vbox,
)

gi.require_foreign("cairo")


def open_path(path: str, model: AppModel) -> None:
    try:
        Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(path).get_uri(), None)
    except GLib.Error as error:
        model.set_error(f"Could not open {path}: {error.message}")


def combo_row(title: str, choices: list[str], selected: int = 0) -> Adw.ComboRow:
    return Adw.ComboRow(title=title, model=Gtk.StringList.new(choices), selected=selected)


# MARK: - Timers


class TimersPage(Page):
    def __init__(self, model: AppModel):
        super().__init__(model, "Timers", "Several can run at once — start as many as you need.")
        self.stop_all = Gtk.Button(label="Stop All")
        self.stop_all.connect("clicked", lambda _b: model.stop_all())
        self.trailing.append(self.stop_all)

        self.hint = empty_hint(
            "system-users-symbolic", "No projects yet",
            "Add a client and at least one project in Clients & Projects, then you can start timing against it.",
        )
        self.running_box = vbox(8)
        self.filter = Gtk.SearchEntry(placeholder_text="Filter", width_request=200)
        self.filter.connect("search-changed", lambda _e: self._fill_grid())
        self.grid = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=10, row_spacing=10,
                                min_children_per_line=1, max_children_per_line=4, homogeneous=True)

        start_header = hbox(12)
        start_header.append(section_title("Start a timer"))
        start_header.get_first_child().set_hexpand(True)
        start_header.append(self.filter)

        content = vbox(20, margin_start=20, margin_end=20, margin_bottom=24)
        content.append(self.running_box)
        start = vbox(8)
        start.append(start_header)
        start.append(self.grid)
        content.append(start)
        self.content = scrolled(content)
        self.append(self.hint)
        self.append(self.content)

    def refresh(self) -> None:
        model = self.model
        self.live = []
        self.stop_all.set_sensitive(bool(model.running))
        self.hint.set_visible(not model.projects)
        self.content.set_visible(bool(model.projects))

        clear(self.running_box)
        self.running_box.set_visible(bool(model.running))
        if model.running:
            self.running_box.append(section_title("Running"))
            for entry in model.running:
                self.running_box.append(self._running_card(entry))
        self._fill_grid()

    def _running_card(self, entry: Entry) -> Gtk.Box:
        model = self.model
        card = hbox(14, css_classes=["running-card"])
        card.append(dot())

        info = vbox(4, hexpand=True, valign=Gtk.Align.CENTER)
        info.append(label(entry.project_name, "heading", ellipsize=True))
        info.append(label(entry.client_name, "caption", "dim-label", ellipsize=True))
        note = Gtk.Entry(placeholder_text="What are you working on?", width_chars=6,
                         text=model.note_drafts.get(entry.id, entry.note))

        def typed(field: Gtk.Entry) -> None:
            model.note_drafts[entry.id] = field.get_text()

        note.connect("changed", typed)
        note.connect("activate", lambda _e: model.commit_notes())
        info.append(note)
        card.append(info)

        clock = vbox(3, valign=Gtk.Align.CENTER)
        clock.append(self.live_label([entry], False, "live-clock"))
        clock.append(label(f"started {core.fmt_time(entry.started_at)}", "caption", "dim-label", xalign=1))
        card.append(clock)

        buttons = vbox(6, valign=Gtk.Align.CENTER)
        stop = icon_label_button("media-playback-stop-symbolic", "Stop", "suggested-action")
        stop.connect("clicked", lambda _b: model.stop_timer(entry))
        discard = Gtk.Button(label="Discard", css_classes=["flat", "error", "caption"])
        discard.connect("clicked", lambda _b: model.cancel_timer(entry))
        buttons.append(stop)
        buttons.append(discard)
        card.append(buttons)
        return card

    def _fill_grid(self) -> None:
        model = self.model
        self.grid.remove_all()
        query = self.filter.get_text().strip().lower()
        for project in model.projects:
            if query and query not in project.name.lower() and query not in project.client_name.lower():
                continue
            self.grid.append(self._project_tile(project))

    def _project_tile(self, project: Project) -> Gtk.Box:
        model = self.model
        tile = hbox(10, css_classes=["project-tile"])
        info = vbox(2, hexpand=True)
        info.append(label(project.name, "heading", ellipsize=True))
        info.append(label(project.client_name, "caption", "dim-label", ellipsize=True))
        tile.append(info)

        today = model.today_entries_for(project.id)
        if today:
            tile.append(self.live_label(today, True, "caption", "dim-label"))

        running = model.is_running(project.id)
        button = Gtk.Button(
            icon_name="list-add-symbolic" if running else "media-playback-start-symbolic",
            valign=Gtk.Align.CENTER,
            tooltip_text=("Start a second timer on this project" if running else f"Start timing {project.name}"),
            css_classes=["circular", "flat"] if running else ["circular", "suggested-action"],
        )
        button.connect("clicked", lambda _b: model.start_timer(project.id))
        tile.append(button)
        return tile


# MARK: - Entries


class EntriesPage(Page):
    def __init__(self, model: AppModel):
        super().__init__(model, "Entries", "Entries count toward the day they started on.")
        self.add_button = icon_label_button("list-add-symbolic", "Add Entry")
        self.add_button.connect("clicked", lambda _b: EntryEditor(model, None).present(self))
        self.trailing.append(self.add_button)

        self.period = PeriodBar(model)
        self.append(self.period)
        self.stats = vbox(margin_start=20, margin_end=20, margin_bottom=12)
        self.append(self.stats)
        self.hint = empty_hint("view-list-symbolic", "Nothing logged in this period",
                               "Start a timer, or use Add Entry to record time you tracked elsewhere.")
        self.append(self.hint)
        self.rows = vbox(margin_start=20, margin_end=20, margin_bottom=20)
        self.scroller = scrolled(self.rows)
        self.append(self.scroller)

    def coarse(self) -> None:
        self.refresh()

    def refresh(self) -> None:
        model = self.model
        self.add_button.set_sensitive(bool(model.projects))
        self.period.refresh()
        clear(self.stats)
        self.stats.append(stat_row([
            ("Entries", str(len(model.visible_entries))),
            ("Time", fmt_duration(model.total_seconds)),
            ("Hours", fmt_hours(model.total_seconds)),
            ("Value", fmt_money(model.total_amount_cents), True),
        ]))
        has_entries = bool(model.visible_entries)
        self.hint.set_visible(not has_entries)
        self.scroller.set_visible(has_entries)
        offset = self.scroller.get_vadjustment().get_value()
        clear(self.rows)
        for entry in model.visible_entries:
            self.rows.append(self._row(entry))
            self.rows.append(divider())
        GLib.idle_add(self.scroller.get_vadjustment().set_value, offset)

    def _row(self, entry: Entry) -> Gtk.Box:
        model = self.model
        now = model.now
        row = hbox(12, margin_top=9, margin_bottom=9)

        when = vbox(2, valign=Gtk.Align.CENTER)
        when.set_size_request(120, -1)
        when.append(label(core.fmt_day_label(entry.started_at), "caption-heading"))
        end = core.fmt_time(entry.ended_at) if entry.ended_at else "now"
        when.append(label(f"{core.fmt_time(entry.started_at)} – {end}", "caption", "dim-label"))
        row.append(when)

        info = vbox(2, hexpand=True, valign=Gtk.Align.CENTER)
        title = hbox(6)
        title.append(label(entry.project_name, "heading", ellipsize=True))
        if entry.is_running:
            title.append(label("RUNNING", "badge", "badge-running"))
        if entry.invoice_id is not None:
            title.append(label("INVOICED", "badge", "badge-invoiced"))
        info.append(title)
        detail = f"{entry.client_name} — {entry.note}" if entry.note else entry.client_name
        note = label(detail, "caption", "dim-label", ellipsize=True)
        note.set_lines(2)
        info.append(note)
        row.append(info)

        seconds = entry.seconds(now)
        row.append(label(fmt_duration(seconds), "numeric", xalign=1, width=70))
        row.append(label(fmt_hours(seconds), "numeric", "dim-label", xalign=1, width=50))
        row.append(label(fmt_money(entry.amount_cents(now)), "numeric", xalign=1, width=84))

        editable = entry.invoice_id is None
        items: list = [("Edit…", lambda: EntryEditor(model, entry).present(self), editable, False)]
        if entry.is_running:
            items.append(("Stop", lambda: model.stop_timer(entry), True, False))
        items += [None, ("Delete", lambda: model.delete_entry(entry), editable, True)]
        row.append(action_menu(items))
        return row


class EntryEditor(EditorDialog):
    """Creates a manual entry when `entry` is None, otherwise edits one."""

    DURATION, START_END = 0, 1

    def __init__(self, model: AppModel, entry: Optional[Entry]):
        super().__init__("Add Entry" if entry is None else "Edit Entry", "Add" if entry is None else "Save")
        self.model = model
        self.entry = entry
        self.running = entry is not None and entry.is_running
        self.projects = model.projects[:]
        # An entry can point at an archived project, which `model.projects` omits.
        if entry and all(p.id != entry.project_id for p in self.projects):
            self.projects += [p for p in model.store.projects(include_archived=True) if p.id == entry.project_id]

        now = datetime.now().replace(microsecond=0)
        if entry:
            start, end = entry.started_at, entry.ended_at or now
        else:
            # An hour ending now: the common "I forgot to start it" case.
            start, end = now - timedelta(hours=1), now
        self.mode = self.START_END if entry else self.DURATION

        selected = next((i for i, p in enumerate(self.projects) if entry and p.id == entry.project_id), 0)
        self.project_row = combo_row("Project", [p.display_name for p in self.projects], selected)
        self.group.add(self.project_row)

        self.start = DateTimeButton(start, on_change=self.update_state)
        self.end = DateTimeButton(end, on_change=self.update_state)
        self.start_row = Adw.ActionRow(title="Start")
        self.start_row.add_suffix(self.start)

        if self.running:
            self.group.add(self.start_row)
            end_row = Adw.ActionRow(title="End", subtitle="Still running — set when you stop the timer.")
            self.group.add(end_row)
        else:
            self.mode_row = combo_row("Enter as", ["Duration", "Start & End"], self.mode)
            self.mode_row.connect("notify::selected", self._mode_changed)
            self.group.add(self.mode_row)
            self.group.add(self.start_row)

            self.end_row = Adw.ActionRow(title="End")
            self.end_row.add_suffix(self.end)
            self.group.add(self.end_row)

            self.hours = Gtk.Entry(placeholder_text="0", width_chars=5, xalign=1, valign=Gtk.Align.CENTER,
                                   text="" if entry else "1")
            self.minutes = Gtk.Entry(placeholder_text="0", width_chars=5, xalign=1, valign=Gtk.Align.CENTER,
                                     text="" if entry else "0")
            for field in (self.hours, self.minutes):
                field.connect("changed", lambda _e: self.update_state())
            self.duration_row = Adw.ActionRow(title="Duration")
            for widget in (self.hours, label("h", "dim-label"), self.minutes, label("m", "dim-label")):
                self.duration_row.add_suffix(widget)
            self.group.add(self.duration_row)

            self.total_row = Adw.ActionRow(title="Total")
            self.total = label("—", "numeric")
            self.total_row.add_suffix(self.total)
            self.group.add(self.total_row)

        self.note = TextRow("Description", entry.note if entry else "")
        self.group.add(self.note)
        self.warning = label("", "caption", "warning", wrap=True)
        self.body.append(self.warning)
        self.update_state()

    def _mode_changed(self, row: Adw.ComboRow, _param) -> None:
        """Carries the value across, so switching never discards what was typed."""
        self.mode = row.get_selected()
        if self.mode == self.DURATION:
            seconds = max(0, int((self.end.value - self.start.value).total_seconds()))
            self.hours.set_text(str(seconds // 3600) if seconds >= 3600 else "")
            self.minutes.set_text(str(seconds % 3600 // 60))
        else:
            seconds = core.parse_duration(self.hours.get_text(), self.minutes.get_text())
            if seconds is not None:
                self.end.value = self.start.value + timedelta(seconds=seconds)
        self.update_state()

    @property
    def duration_seconds(self) -> Optional[int]:
        if self.mode == self.START_END:
            seconds = int((self.end.value - self.start.value).total_seconds())
            return seconds if seconds >= 0 else None
        return core.parse_duration(self.hours.get_text(), self.minutes.get_text())

    @property
    def resolved_end(self) -> Optional[datetime]:
        """In duration mode the end time is derived, never typed."""
        seconds = self.duration_seconds
        if seconds is None:
            return None
        return self.end.value if self.mode == self.START_END else self.start.value + timedelta(seconds=seconds)

    def update_state(self) -> None:
        if self.running:
            self.warning.set_visible(False)
            self.save_button.set_sensitive(bool(self.projects))
            return
        is_duration = self.mode == self.DURATION
        self.start_row.set_title("Started" if is_duration else "Start")
        self.end_row.set_visible(not is_duration)
        self.duration_row.set_visible(is_duration)

        seconds = self.duration_seconds
        if seconds:
            text = f"{fmt_hours(seconds)} hours · {fmt_duration(seconds)}"
            if is_duration:
                text += f" · ends {core.fmt_time(self.resolved_end)}"
            self.total.set_text(text)
        else:
            self.total.set_text("—")

        if is_duration:
            warning = ("Enter hours and minutes as plain numbers." if seconds is None
                       else "Enter a duration greater than zero." if seconds == 0 else "")
        else:
            warning = "The end time is before the start time." if self.end.value < self.start.value else ""
        self.warning.set_text(warning)
        self.warning.set_visible(bool(warning))
        self.save_button.set_sensitive(bool(self.projects) and bool(seconds))

    def on_save(self) -> None:
        project_id = self.projects[self.project_row.get_selected()].id
        note = self.note.text
        if self.entry:
            # A running entry stays running: keep its empty end.
            end = None if self.running else self.resolved_end
            self.model.update_entry(self.entry.id, project_id, self.start.value, end, note)
        else:
            self.model.add_manual_entry(project_id, self.start.value, self.resolved_end, note)
        self.close()


# MARK: - Reports


class DailyBarChart(Gtk.DrawingArea):
    """Hand-drawn, as in the macOS app: it's a bar per day."""

    LABEL_HEIGHT = 30

    def __init__(self, days: list[core.DayTotal]):
        super().__init__(content_height=150, hexpand=True)
        self.days = days
        self.set_draw_func(self._draw)

    def _text(self, ctx, text: str, x: float, y: float, width: float, color) -> None:
        layout = self.create_pango_layout(text)
        description = Pango.FontDescription()
        description.set_absolute_size(9 * Pango.SCALE)
        layout.set_font_description(description)
        layout.set_width(int(width * Pango.SCALE))
        layout.set_wrap(Pango.WrapMode.WORD)
        layout.set_alignment(Pango.Alignment.CENTER)
        ctx.set_source_rgba(color.red, color.green, color.blue, 0.6)
        ctx.move_to(x, y)
        PangoCairo.show_layout(ctx, layout)

    @staticmethod
    def _rounded(ctx, x, y, width, height, radius=3.0) -> None:
        radius = min(radius, width / 2, height / 2)
        ctx.new_sub_path()
        ctx.arc(x + width - radius, y + radius, radius, -math.pi / 2, 0)
        ctx.arc(x + width - radius, y + height - radius, radius, 0, math.pi / 2)
        ctx.arc(x + radius, y + height - radius, radius, math.pi / 2, math.pi)
        ctx.arc(x + radius, y + radius, radius, math.pi, 3 * math.pi / 2)
        ctx.close_path()

    def _draw(self, _area, ctx, width: int, height: int) -> None:
        count = max(len(self.days), 1)
        spacing = 4 if count > 7 else 8
        bar_width = max(6.0, (width - spacing * (count - 1)) / count)
        plot_height = max(1, height - self.LABEL_HEIGHT)
        peak = max(max((d.seconds for d in self.days), default=0), 1)
        foreground = self.get_color()
        accent = Adw.StyleManager.get_default().get_accent_color_rgba()

        for index, day in enumerate(self.days):
            x = index * (bar_width + spacing)
            ctx.set_source_rgba(foreground.red, foreground.green, foreground.blue, 0.07)
            self._rounded(ctx, x, 0, bar_width, plot_height)
            ctx.fill()
            if day.seconds > 0:
                bar_height = plot_height * day.seconds / peak
                ctx.set_source_rgba(accent.red, accent.green, accent.blue, 1)
                self._rounded(ctx, x, plot_height - bar_height, bar_width, bar_height)
                ctx.fill()
                # Sits above the bar, or just inside the top when the bar is full height.
                text_y = max(1, plot_height - bar_height - 13)
                self._text(ctx, fmt_hours(day.seconds), x, text_y, bar_width, foreground)
            self._text(ctx, core.fmt_day_label(day.day), x, plot_height + 5, bar_width, foreground)


class ReportsPage(Page):
    def __init__(self, model: AppModel):
        super().__init__(model, "Reports", "Totals by day, week, and two-week period.")
        self.expanded: set[int] = set()
        self.period = PeriodBar(model)
        self.append(self.period)
        self.content = vbox(22, margin_start=20, margin_end=20, margin_bottom=26)
        self.scroller = scrolled(self.content)
        self.append(self.scroller)

    def on_enter(self) -> None:
        # Opens on today rather than wherever the controls were left in Entries.
        self.model.show_today()

    def coarse(self) -> None:
        self.refresh()

    def refresh(self) -> None:
        model = self.model
        self.period.refresh()
        offset = self.scroller.get_vadjustment().get_value()
        clear(self.content)

        days = model.day_totals
        worked = [d.seconds for d in days if d.seconds > 0]
        average = sum(worked) // len(worked) if worked else 0
        self.content.append(stat_row([
            ("Total hours", fmt_hours(model.total_seconds)),
            ("Time", fmt_duration(model.total_seconds)),
            ("Avg / worked day", fmt_duration(average)),
            ("Billable value", fmt_money(model.total_amount_cents), True),
        ]))

        if len(days) > 1:
            chart = vbox(10)
            chart.append(section_title("Daily"))
            chart.append(DailyBarChart(days))
            self.content.append(chart)

        if not model.visible_entries:
            self.content.append(empty_hint("x-office-document-symbolic", "No time in this period",
                                           "Once you log some time it will break down by client and project here."))
        else:
            section = vbox(0)
            section.append(section_title("By client"))
            projects = model.project_breakdown
            for row, amount in model.client_breakdown:
                section.append(self._client_row(row, amount, [p for p in projects if p.client_id == row.client_id]))
                section.append(divider())
            self.content.append(section)
        GLib.idle_add(self.scroller.get_vadjustment().set_value, offset)

    def _toggle(self, client_id: int) -> None:
        self.expanded.symmetric_difference_update({client_id})
        self.refresh()

    def _client_row(self, row: core.BreakdownRow, amount: int, projects: list[core.BreakdownRow]) -> Gtk.Box:
        total = self.model.total_seconds
        share = row.seconds / total if total > 0 else 0
        is_open = row.client_id in self.expanded

        line = hbox(10, margin_top=5, margin_bottom=5)
        line.append(Gtk.Image(icon_name="go-down-symbolic" if is_open else "go-next-symbolic", pixel_size=12))
        line.append(label(row.client_name, "heading", ellipsize=True, hexpand=True))
        bar = Gtk.ProgressBar(fraction=share, valign=Gtk.Align.CENTER, width_request=120)
        line.append(bar)
        line.append(label(f"{core.rounded(share * 100)}%", "caption", "numeric", "dim-label", xalign=1, width=38))
        line.append(label(fmt_duration(row.seconds), "numeric", xalign=1, width=74))
        line.append(label(fmt_hours(row.seconds), "numeric", "dim-label", xalign=1, width=50))
        line.append(label(fmt_money(amount), "numeric", xalign=1, width=88))
        button = Gtk.Button(child=line, css_classes=["flat"])
        button.connect("clicked", lambda _b: self._toggle(row.client_id))

        box = vbox()
        box.append(button)
        if is_open:
            for project in projects:
                detail = hbox(10, margin_top=4, margin_bottom=4, margin_start=34, margin_end=12)
                detail.append(label(project.project_name or "—", "caption", "dim-label",
                                    ellipsize=True, hexpand=True))
                detail.append(label(f"{fmt_money(project.rate_cents)}/h", "caption", "numeric", "dim-label",
                                    xalign=1, width=120))
                detail.append(label(fmt_duration(project.seconds), "caption", "numeric", xalign=1, width=74))
                detail.append(label(fmt_hours(project.seconds), "caption", "numeric", "dim-label", xalign=1, width=50))
                detail.append(label(fmt_money(project.amount_cents), "caption", "numeric", xalign=1, width=88))
                box.append(detail)
        return box


# MARK: - Clients & projects


class ClientsPage(Page):
    def __init__(self, model: AppModel):
        super().__init__(model, "Clients & Projects", "Rates live on the client; a project can override its own.")
        self.selected_id: Optional[int] = None
        self._loading = False

        add = icon_label_button("list-add-symbolic", "Add Client")
        add.connect("clicked", lambda _b: ClientEditor(model, None).present(self))
        self.trailing.append(add)

        self.hint = empty_hint("system-users-symbolic", "No clients yet",
                               "Add your first client and its hourly rate. Then add one or more projects "
                               "to bill time against.")
        self.append(self.hint)

        self.list = Gtk.ListBox(css_classes=["navigation-sidebar"], selection_mode=Gtk.SelectionMode.SINGLE)
        self.list.connect("row-selected", self._row_selected)
        self.detail = vbox()
        self.paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL, vexpand=True, position=280,
                               shrink_start_child=False, shrink_end_child=False, wide_handle=False)
        left = scrolled(self.list)
        left.set_size_request(230, -1)
        self.paned.set_start_child(left)
        self.paned.set_end_child(self.detail)
        self.append(divider())
        self.append(self.paned)

    @property
    def selected_client(self) -> Optional[Client]:
        clients = self.model.clients
        return next((c for c in clients if c.id == self.selected_id), clients[0] if clients else None)

    def _row_selected(self, _list, row: Optional[Gtk.ListBoxRow]) -> None:
        if row is not None and not self._loading:
            self.selected_id = self.model.clients[row.get_index()].id
            self._fill_detail()

    def refresh(self) -> None:
        model = self.model
        self.hint.set_visible(not model.clients)
        self.paned.set_visible(bool(model.clients))
        self._loading = True
        self.list.remove_all()
        selected = self.selected_client
        for client in model.clients:
            count = len(model.projects_for(client.id))
            row = hbox(6, margin_top=4, margin_bottom=4)
            info = vbox(2, hexpand=True)
            info.append(label(client.name, "heading", ellipsize=True))
            info.append(label(f"{fmt_money(client.hourly_rate_cents)}/h · {count} project{'' if count == 1 else 's'}",
                              "caption", "dim-label", ellipsize=True))
            row.append(info)
            row.append(action_menu([
                ("Edit…", lambda c=client: ClientEditor(model, c).present(self), True, False),
                ("Add Project…", lambda c=client: ProjectEditor(model, c.id, None).present(self), True, False),
                None,
                ("Delete", lambda c=client: model.delete_client(c), True, True),
            ]))
            self.list.append(row)
            if selected and client.id == selected.id:
                self.list.select_row(self.list.get_row_at_index(self.list.observe_children().get_n_items() - 1))
        self._loading = False
        self._fill_detail()

    def _fill_detail(self) -> None:
        model = self.model
        clear(self.detail)
        client = self.selected_client
        if client is None:
            return

        header = hbox(8, margin_start=18, margin_end=18, margin_top=14, margin_bottom=14)
        info = vbox(3, hexpand=True)
        info.append(label(client.name, "title-3", ellipsize=True))
        info.append(label(f"Default rate {fmt_money(client.hourly_rate_cents)}/h", "caption", "dim-label"))
        if client.address:
            info.append(label(client.address, "caption", "dim-label", wrap=True))
        header.append(info)
        edit = Gtk.Button(label="Edit Client", valign=Gtk.Align.CENTER)
        edit.connect("clicked", lambda _b: ClientEditor(model, client).present(self))
        add = icon_label_button("list-add-symbolic", "Add Project")
        add.set_valign(Gtk.Align.CENTER)
        add.connect("clicked", lambda _b: ProjectEditor(model, client.id, None).present(self))
        header.append(edit)
        header.append(add)
        self.detail.append(header)
        self.detail.append(divider())

        projects = model.projects_for(client.id)
        if not projects:
            self.detail.append(empty_hint("folder-symbolic", f"No projects for {client.name}",
                                          "A project is the project or case you bill against. "
                                          "Add one to start timing."))
            return
        rows = vbox()
        for project in projects:
            rows.append(self._project_row(project))
            rows.append(divider())
        self.detail.append(scrolled(rows))

    def _project_row(self, project: Project) -> Gtk.Box:
        model = self.model
        row = hbox(10, margin_start=18, margin_end=18, margin_top=10, margin_bottom=10)
        info = vbox(2, hexpand=True)
        info.append(label(project.name, ellipsize=True))
        custom = project.hourly_rate_cents is not None
        rate = label(f"{'Custom' if custom else 'Client'} rate · {fmt_money(project.effective_rate_cents)}/h",
                     "caption", "warning" if custom else "dim-label")
        info.append(rate)
        row.append(info)
        if model.is_running(project.id):
            row.append(dot())
        start = Gtk.Button(label="Start", valign=Gtk.Align.CENTER)
        start.connect("clicked", lambda _b: model.start_timer(project.id))
        row.append(start)
        row.append(action_menu([
            ("Edit…", lambda: ProjectEditor(model, project.client_id, project).present(self), True, False),
            None,
            ("Delete", lambda: model.delete_project(project), True, True),
        ]))
        return row


class ClientEditor(EditorDialog):
    def __init__(self, model: AppModel, client: Optional[Client]):
        super().__init__("New Client" if client is None else "Edit Client", "Save", 420)
        self.model = model
        self.client = client
        self.name = Adw.EntryRow(title="Name", text=client.name if client else "")
        rate = f"{client.hourly_rate_cents / 100:.2f}" if client else ""
        self.rate = Adw.EntryRow(title="Hourly rate (e.g. 250.00)", text=rate)
        self.address = TextRow("Billing address", client.address if client else "")
        self.notes = TextRow("Notes", client.notes if client else "")
        for row in (self.name, self.rate, self.address, self.notes):
            self.group.add(row)
        self.archived = Adw.SwitchRow(title="Archived", active=bool(client and client.archived))
        if client:
            self.group.add(self.archived)
        self.name.connect("changed", lambda _r: self._validate())
        self.rate.connect("changed", lambda _r: self._validate())
        self._validate()

    def _validate(self) -> None:
        valid = bool(self.name.get_text().strip()) and core.parse_money(self.rate.get_text()) is not None
        self.save_button.set_sensitive(valid)

    def on_save(self) -> None:
        name = self.name.get_text().strip()
        rate = core.parse_money(self.rate.get_text())
        if self.client:
            self.model.update_client(core.replace(
                self.client, name=name, hourly_rate_cents=rate, address=self.address.text,
                notes=self.notes.text, archived=self.archived.get_active(),
            ))
        else:
            self.model.create_client(name, rate, self.address.text, self.notes.text)
        self.close()


class ProjectEditor(EditorDialog):
    def __init__(self, model: AppModel, client_id: int, project: Optional[Project]):
        super().__init__("New Project" if project is None else "Edit Project", "Save", 420)
        self.model = model
        self.client_id = client_id
        self.project = project
        override = project.hourly_rate_cents if project else None
        client_rate = next((c.hourly_rate_cents for c in model.clients if c.id == client_id), 0)

        self.name = Adw.EntryRow(title="Project name", text=project.name if project else "")
        self.custom = Adw.SwitchRow(title="Override the client rate", active=override is not None)
        self.rate = Adw.EntryRow(title="Hourly rate (e.g. 300.00)",
                                 text=f"{override / 100:.2f}" if override is not None else "")
        self.inherited = Adw.ActionRow(title="Rate", subtitle=f"{fmt_money(client_rate)}/h (from client)")
        for row in (self.name, self.custom, self.rate, self.inherited):
            self.group.add(row)
        self.archived = Adw.SwitchRow(title="Archived", active=bool(project and project.archived))
        if project:
            self.group.add(self.archived)
        self.name.connect("changed", lambda _r: self._validate())
        self.rate.connect("changed", lambda _r: self._validate())
        self.custom.connect("notify::active", lambda *_a: self._validate())
        self._validate()

    def _validate(self) -> None:
        custom = self.custom.get_active()
        self.rate.set_visible(custom)
        self.inherited.set_visible(not custom)
        rate_ok = not custom or core.parse_money(self.rate.get_text()) is not None
        self.save_button.set_sensitive(bool(self.name.get_text().strip()) and rate_ok)

    def on_save(self) -> None:
        name = self.name.get_text().strip()
        rate = core.parse_money(self.rate.get_text()) if self.custom.get_active() else None
        if self.project:
            self.model.update_project(core.replace(
                self.project, name=name, hourly_rate_cents=rate, archived=self.archived.get_active(),
            ))
        else:
            self.model.create_project(self.client_id, name, rate)
        self.close()


# MARK: - Invoices


class InvoicesPage(Page):
    def __init__(self, model: AppModel):
        super().__init__(model, "Invoices", "Bills stopped, not-yet-invoiced time for one client, or several combined.")
        # Ticked clients, in the order they were ticked. The first is the one billed.
        self.selected: list[int] = []
        self.clients: list[Client] = []
        self.billable: list[Entry] = []
        self.hint = empty_hint("x-office-document-symbolic", "No clients yet",
                               "Add a client with a rate before generating an invoice.")
        self.append(self.hint)

        current = core.two_week_range(datetime.now(), model.settings.period_anchor)
        self.client_list = vbox(2)
        client_popover = Gtk.Popover()
        client_popover.set_child(self.client_list)
        self.client_button = Gtk.MenuButton(popover=client_popover, valign=Gtk.Align.CENTER)
        self.client_button.set_size_request(240, -1)
        self.from_date = DateTimeButton(current.start, with_time=False, on_change=self.reload)
        self.to_date = DateTimeButton(current.last_day, with_time=False, on_change=self.reload)
        last = Gtk.Button(label="Last 2 Weeks")
        last.connect("clicked", self._last_two_weeks)

        controls = hbox(12)
        controls.append(label("Bill to", "dim-label"))
        controls.append(self.client_button)
        for caption, widget in (("From", self.from_date), ("To", self.to_date)):
            controls.append(label(caption, "dim-label"))
            controls.append(widget)
        controls.append(last)

        self.stats = vbox()
        self.generate_button = icon_label_button("document-save-symbolic", "Generate PDF…", "suggested-action")
        self.generate_button.connect("clicked", self._generate)
        self.running_note = label("", "caption", "dim-label", wrap=True, hexpand=True)
        actions = hbox(12)
        actions.append(self.generate_button)
        actions.append(self.running_note)

        self.lines = vbox()
        self.history = vbox()
        content = vbox(20, margin_start=20, margin_end=20, margin_bottom=24)
        top = vbox(12)
        for widget in (controls, self.stats, actions):
            top.append(widget)
        preview = vbox(8)
        preview.append(section_title("Lines on this invoice"))
        preview.append(self.lines)
        for widget in (top, preview, self.history):
            content.append(widget)
        self.scroller = scrolled(content)
        self.append(self.scroller)

    # State

    @property
    def period(self) -> core.DateRange:
        start = self.from_date.day
        end = self.to_date.day + timedelta(days=1)
        return core.DateRange(start, max(end, start))

    @property
    def invoice_number(self) -> str:
        settings = self.model.settings
        return f"{settings.invoice_prefix}{settings.next_invoice_number:04d}"

    @property
    def selected_client(self) -> Optional[Client]:
        """The client billed: whichever was ticked first."""
        return next((c for c in self.clients if self.selected and c.id == self.selected[0]), None)

    def _client_toggled(self, button: Gtk.CheckButton, client_id: int) -> None:
        if button.get_active():
            self.selected.append(client_id)
        else:
            self.selected.remove(client_id)
        self._show_selected()
        self.reload()

    def _show_selected(self) -> None:
        names = {c.id: c.name for c in self.clients}
        self.client_button.set_label(" + ".join(names[i] for i in self.selected) or "Choose Clients…")

    def _fill_clients(self) -> None:
        clear(self.client_list)
        for client in self.clients:
            check = Gtk.CheckButton(label=client.name, active=client.id in self.selected)
            check.connect("toggled", self._client_toggled, client.id)
            self.client_list.append(check)
        self._show_selected()

    def _last_two_weeks(self, _button) -> None:
        previous = core.two_week_range(datetime.now() - timedelta(days=14), self.model.settings.period_anchor)
        self.from_date.value = previous.start
        self.to_date.value = previous.last_day
        self.reload()

    def refresh(self) -> None:
        model = self.model
        self.hint.set_visible(not model.clients)
        self.scroller.set_visible(bool(model.clients))
        first_visit = not self.clients
        self.clients = model.clients[:]
        current = {c.id for c in self.clients}
        self.selected = [i for i in self.selected if i in current]
        if first_visit and self.clients:
            self.selected = [self.clients[0].id]
        self._fill_clients()
        self.reload()

    def reload(self) -> None:
        model = self.model
        self.billable = []
        try:
            self.billable = sorted(
                (entry for client_id in self.selected
                 for entry in model.store.billable_entries(client_id, self.period)),
                key=lambda entry: entry.started_at,
            )
        except Exception as error:  # surfaced in the banner, never a crash
            model.set_error(str(error))

        total_seconds = sum(e.seconds(e.ended_at) for e in self.billable)
        total_cents = sum(e.amount_cents(e.ended_at) for e in self.billable)
        clear(self.stats)
        self.stats.append(stat_row([
            ("Invoice no.", self.invoice_number),
            ("Entries", str(len(self.billable))),
            ("Hours", fmt_hours(total_seconds)),
            ("Amount due", fmt_money(total_cents), True),
        ]))
        self.generate_button.set_sensitive(bool(self.billable) and self.selected_client is not None)
        count = len(model.running)
        self.running_note.set_text(
            f"{count} timer{'' if count == 1 else 's'} still running — that time won't be included until stopped."
            if count else ""
        )
        self._fill_lines()
        self._fill_history()

    def _fill_lines(self) -> None:
        clear(self.lines)
        if not self.billable:
            self.lines.append(label("No uninvoiced, stopped time for this client in this date range.", "dim-label"))
            return
        for entry in self.billable:
            end = entry.ended_at
            row = hbox(12, margin_top=5, margin_bottom=5)
            row.append(label(core.fmt_compact_date(entry.started_at), "caption", "numeric", "dim-label", width=60))
            project = f"{entry.client_name} › {entry.project_name}" if len(self.selected) > 1 else entry.project_name
            row.append(label(project, "caption", width=150, ellipsize=True))
            row.append(label(entry.note or "—", "caption", "dim-label", ellipsize=True, hexpand=True))
            row.append(label(fmt_hours(entry.seconds(end)), "caption", "numeric", xalign=1, width=48))
            row.append(label(fmt_money(entry.rate_cents), "caption", "numeric", "dim-label", xalign=1, width=70))
            row.append(label(fmt_money(entry.amount_cents(end)), "caption", "numeric", xalign=1, width=80))
            self.lines.append(row)
            self.lines.append(divider())

    def _fill_history(self) -> None:
        clear(self.history)
        invoices = self.model.invoices
        self.history.set_visible(bool(invoices))
        if not invoices:
            return
        self.history.append(section_title("Issued"))
        for invoice in invoices:
            has_file = bool(invoice.file_path)
            row = hbox(12, margin_top=6, margin_bottom=6)
            row.append(label(invoice.number, "caption-heading", "numeric", width=90))
            row.append(label(invoice.client_label, "caption", width=160, ellipsize=True))
            period = f"{core.fmt_compact_date(invoice.period_start)} – {core.fmt_compact_date(invoice.period_end)}"
            row.append(label(period, "caption", "dim-label", hexpand=True))
            row.append(label(f"{fmt_hours(invoice.seconds)} h", "caption", "numeric", "dim-label", xalign=1, width=64))
            row.append(label(fmt_money(invoice.total_cents), "caption", "numeric", xalign=1, width=84))
            row.append(action_menu([
                ("Open PDF", lambda i=invoice: open_path(i.file_path, self.model), has_file, False),
                ("Show in Files", lambda i=invoice: open_path(os.path.dirname(i.file_path), self.model),
                 has_file, False),
                None,
                ("Delete & Unbill Entries", lambda i=invoice: self._delete(i), True, True),
            ]))
            self.history.append(row)
            self.history.append(divider())

    # Actions

    def _generate(self, _button) -> None:
        client = self.selected_client
        if client is None or not self.billable:
            return
        stamp = self.period.last_day.strftime("%Y-%m-%d")
        name = f"{self.invoice_number} {client.name} {stamp}.pdf".replace("/", "-")
        pdf_filter = Gtk.FileFilter(name="PDF")
        pdf_filter.add_mime_type("application/pdf")
        filters = Gio.ListStore.new(Gtk.FileFilter)
        filters.append(pdf_filter)
        dialog = Gtk.FileDialog(title="Save Invoice", initial_name=name, filters=filters)

        def chosen(source, result):
            try:
                target = source.save_finish(result)
            except GLib.Error:
                return  # dismissed
            path = target.get_path()
            if path:
                self._write_invoice(client, path if path.lower().endswith(".pdf") else f"{path}.pdf")

        dialog.save(self.get_root(), None, chosen)

    def _write_invoice(self, client: Client, path: str) -> None:
        model = self.model
        number, period, billable = self.invoice_number, self.period, self.billable
        data = invoice_pdf.Input(model.settings, client, number, datetime.now(), period, billable)
        try:
            invoice_pdf.render(data, path)
            model.store.record_invoice(client.id, number, period.start, period.last_day, billable,
                                       data.total_cents, data.total_seconds, path)
        except Exception as error:  # surfaced in the banner, never a crash
            model.set_error(str(error))
            return
        model.settings.next_invoice_number += 1
        model.save_settings()
        model.reload_all()
        open_path(os.path.dirname(path), model)

    def _delete(self, invoice: core.Invoice) -> None:
        try:
            self.model.store.delete_invoice(invoice.id)
        except Exception as error:  # surfaced in the banner, never a crash
            self.model.set_error(str(error))
        self.model.reload_all()


# MARK: - Settings


class SettingsPage(Page):
    def __init__(self, model: AppModel):
        super().__init__(model, "Settings", "Business identity, billing periods, and where your data lives.")
        save = Gtk.Button(label="Save", css_classes=["suggested-action"])
        save.connect("clicked", lambda _b: model.save_settings())
        self.trailing.append(save)
        self._loading = False
        s = model.settings

        self.name = Adw.EntryRow(title="Name")
        self.address = TextRow("Address", on_change=lambda t: self._set("business_address", t))
        self.email = Adw.EntryRow(title="Email")
        self.prefix = Adw.EntryRow(title="Number prefix")
        self.next_number = Adw.SpinRow.new_with_range(1, 999_999, 1)
        self.next_number.set_title("Next invoice number")
        self.terms = TextRow("Payment terms", on_change=lambda t: self._set("invoice_terms", t))
        self.weekday = combo_row("Week starts on", ["Sunday", "Monday"])
        self.anchor = DateTimeButton(s.period_anchor, with_time=False, on_change=self._anchor_changed)
        anchor_row = Adw.ActionRow(title="Two-week periods start from")
        anchor_row.add_suffix(self.anchor)
        self.current_period = Adw.ActionRow(title="Current period")

        self.name.connect("changed", lambda r: self._set("business_name", r.get_text()))
        self.email.connect("changed", lambda r: self._set("business_email", r.get_text()))
        self.prefix.connect("changed", lambda r: self._set("invoice_prefix", r.get_text()))
        self.next_number.connect("notify::value", lambda r, _p: self._set("next_invoice_number", int(r.get_value())))
        self.weekday.connect("notify::selected", lambda r, _p: self._set("first_weekday", r.get_selected() + 1))

        database = Adw.ActionRow(title="Database", subtitle=GLib.markup_escape_text(model.store.path),
                                 subtitle_lines=2)
        show = Gtk.Button(label="Show in Files", valign=Gtk.Align.CENTER)
        show.connect("clicked", lambda _b: open_path(os.path.dirname(model.store.path), model))
        database.add_suffix(show)

        preferences = Adw.PreferencesPage(vexpand=True)
        groups = (
            ("Your business", "", (self.name, self.address, self.email)),
            ("Invoices", "", (self.prefix, self.next_number, self.terms)),
            ("Billing periods", "", (self.weekday, anchor_row, self.current_period)),
            ("Data", "Everything is stored in this one SQLite file. Back it up and your entire "
                     "billing history travels with it.", (database,)),
        )
        for title, description, rows in groups:
            group = Adw.PreferencesGroup(title=title, description=description)
            for row in rows:
                group.add(row)
            preferences.add(group)
        self.append(preferences)

    def _set(self, attribute: str, value) -> None:
        if not self._loading:
            setattr(self.model.settings, attribute, value)
            self._show_period()

    def _anchor_changed(self) -> None:
        self._set("period_anchor", self.anchor.day)

    def _show_period(self) -> None:
        settings = self.model.settings
        period = core.two_week_range(datetime.now(), settings.period_anchor)
        self.current_period.set_subtitle(
            f"{core.fmt_compact_date(period.start)} – {core.fmt_short_date(period.last_day)}"
        )

    def refresh(self) -> None:
        s = self.model.settings
        self._loading = True
        self.name.set_text(s.business_name)
        self.address.text = s.business_address
        self.email.set_text(s.business_email)
        self.prefix.set_text(s.invoice_prefix)
        self.next_number.set_value(s.next_invoice_number)
        self.terms.text = s.invoice_terms
        self.weekday.set_selected(s.first_weekday - 1)
        self.anchor.value = s.period_anchor
        self._loading = False
        self._show_period()

    def on_enter(self) -> None:
        self.refresh()

    def on_leave(self) -> None:
        # Changes take effect once saved, so reporting can't shift underfoot.
        self.model.save_settings()

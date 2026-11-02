"""Data, period math, and formatting. Nothing in here touches GTK.

A straight port of the Swift `DB/` and `Util/` layers. The schema, the
`user_version` numbering, and the stored formats are deliberately identical, so
a `billabletimer.sqlite3` copied from the macOS app opens here unchanged.
"""

from __future__ import annotations

import locale
import math
import os
import sqlite3
from dataclasses import dataclass, field, replace  # noqa: F401 (replace is used as core.replace)
from datetime import date, datetime, time, timedelta
from pathlib import Path
from typing import Optional


class DBError(Exception):
    """A failure worth showing the user as-is."""


def rounded(value: float) -> int:
    """Half-away-from-zero, matching Swift's `.rounded()`.

    Python's own `round()` is banker's rounding, which would land some invoice
    lines a cent away from what the macOS app computes for the same entries.
    """
    return int(math.copysign(math.floor(abs(value) + 0.5), value))


def data_dir() -> Path:
    """`$XDG_DATA_HOME/BillableTimer`, the Linux home of Application Support."""
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return Path(base) / "BillableTimer"


# MARK: - Models


def _ts(value: int) -> datetime:
    return datetime.fromtimestamp(value)


def _stamp(value: datetime) -> int:
    return int(value.timestamp())


@dataclass
class Client:
    id: int
    name: str
    hourly_rate_cents: int
    address: str
    notes: str
    archived: bool

    @staticmethod
    def from_row(row: sqlite3.Row) -> "Client":
        return Client(
            row["id"], row["name"], row["hourly_rate_cents"],
            row["address"], row["notes"], bool(row["archived"]),
        )


@dataclass
class Project:
    id: int
    client_id: int
    client_name: str
    name: str
    hourly_rate_cents: Optional[int]  # None means "use the client's rate"
    archived: bool
    effective_rate_cents: int

    @property
    def display_name(self) -> str:
        return f"{self.client_name} › {self.name}"

    @staticmethod
    def from_row(row: sqlite3.Row) -> "Project":
        override = row["hourly_rate_cents"]
        return Project(
            row["id"], row["client_id"], row["client_name"], row["name"], override,
            bool(row["archived"]),
            override if override is not None else row["client_rate_cents"],
        )


@dataclass
class Entry:
    id: int
    project_id: int
    project_name: str
    client_id: int
    client_name: str
    started_at: datetime
    ended_at: Optional[datetime]
    note: str
    rate_cents: int
    invoice_id: Optional[int]

    @property
    def is_running(self) -> bool:
        return self.ended_at is None

    def seconds(self, as_of: datetime) -> int:
        """Elapsed seconds, derived from wall-clock stamps, never from ticks."""
        end = self.ended_at or as_of
        return max(0, int((end - self.started_at).total_seconds()))

    def hours(self, as_of: datetime) -> float:
        return self.seconds(as_of) / 3600

    def amount_cents(self, as_of: datetime) -> int:
        return rounded(self.hours(as_of) * self.rate_cents)

    @staticmethod
    def from_row(row: sqlite3.Row) -> "Entry":
        ended = row["ended_at"]
        return Entry(
            row["id"], row["project_id"], row["project_name"], row["client_id"],
            row["client_name"], _ts(row["started_at"]),
            _ts(ended) if ended is not None else None,
            row["note"], row["rate_cents"], row["invoice_id"],
        )


@dataclass
class BreakdownRow:
    client_id: int
    client_name: str
    project_id: Optional[int]
    project_name: Optional[str]
    seconds: int
    rate_cents: int

    @property
    def amount_cents(self) -> int:
        return rounded(self.seconds / 3600 * self.rate_cents)


@dataclass
class DayTotal:
    day: datetime
    seconds: int


@dataclass
class Invoice:
    id: int
    client_id: int
    client_name: str
    number: str
    issued_at: datetime
    period_start: datetime
    period_end: datetime
    total_cents: int
    seconds: int
    file_path: str
    # Clients other than the billed one whose time is on this invoice.
    other_clients: str = ""

    @property
    def client_label(self) -> str:
        return f"{self.client_name} + {self.other_clients}" if self.other_clients else self.client_name

    @staticmethod
    def from_row(row: sqlite3.Row) -> "Invoice":
        return Invoice(
            row["id"], row["client_id"], row["client_name"], row["number"],
            _ts(row["issued_at"]), _ts(row["period_start"]), _ts(row["period_end"]),
            row["total_cents"], row["seconds"], row["file_path"], row["other_clients"] or "",
        )


def _today_midnight() -> datetime:
    return datetime.combine(date.today(), time.min)


@dataclass
class AppSettings:
    business_name: str = ""
    business_address: str = ""
    business_email: str = ""
    invoice_terms: str = "Payable within 30 days."
    invoice_prefix: str = "INV-"
    next_invoice_number: int = 1
    first_weekday: int = 2  # Calendar.firstWeekday convention: 1 = Sunday, 2 = Monday
    period_anchor: datetime = field(default_factory=_today_midnight)


# MARK: - Periods


@dataclass(frozen=True)
class DateRange:
    """A half-open range [start, end)."""

    start: datetime
    end: datetime

    def contains(self, value: datetime) -> bool:
        return self.start <= value < self.end

    @property
    def last_day(self) -> datetime:
        """The inclusive last day, for display ("Mar 3 – Mar 16", not "– Mar 17")."""
        return self.end - timedelta(seconds=1)


DAY, WEEK, TWO_WEEKS = "Day", "Week", "Two Weeks"
PERIOD_KINDS = (DAY, WEEK, TWO_WEEKS)
STRIDE_DAYS = {DAY: 1, WEEK: 7, TWO_WEEKS: 14}


def _midnight(day: date) -> datetime:
    # Naive local datetimes, so adding days lands on local midnight across DST.
    return datetime.combine(day, time.min)


def day_range(value: datetime) -> DateRange:
    start = value.date()
    return DateRange(_midnight(start), _midnight(start + timedelta(days=1)))


def week_range(value: datetime, first_weekday: int) -> DateRange:
    start = value.date()
    # Swift weekday: Sunday = 1 ... Saturday = 7. isoweekday: Monday = 1 ... Sunday = 7.
    weekday = start.isoweekday() % 7 + 1
    start -= timedelta(days=(weekday - first_weekday + 7) % 7)
    return DateRange(_midnight(start), _midnight(start + timedelta(days=7)))


def two_week_range(value: datetime, anchor: datetime) -> DateRange:
    """Two-week periods tile the calendar outward from `anchor` in both directions."""
    anchor_day = anchor.date()
    # Floor division, so periods before the anchor tile correctly too.
    index = (value.date() - anchor_day).days // 14
    start = anchor_day + timedelta(days=index * 14)
    return DateRange(_midnight(start), _midnight(start + timedelta(days=14)))


def period_range(kind: str, value: datetime, settings: AppSettings) -> DateRange:
    if kind == DAY:
        return day_range(value)
    if kind == WEEK:
        return week_range(value, settings.first_weekday)
    return two_week_range(value, settings.period_anchor)


def days_in(period: DateRange) -> list[datetime]:
    days = []
    cursor = period.start.date()
    while _midnight(cursor) < period.end:
        days.append(_midnight(cursor))
        cursor += timedelta(days=1)
    return days


# MARK: - Formatting


def fmt_clock(seconds: int) -> str:
    seconds = max(0, seconds)
    return f"{seconds // 3600}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}"


def fmt_duration(seconds: int) -> str:
    seconds = max(0, seconds)
    hours, minutes = seconds // 3600, seconds % 3600 // 60
    return f"{minutes}m" if hours == 0 else f"{hours}h {minutes:02d}m"


def fmt_hours(seconds: int) -> str:
    return f"{max(0, seconds) / 3600:.2f}"


def fmt_money(cents: int) -> str:
    try:
        return locale.currency(cents / 100, grouping=True)
    except ValueError:  # the C locale has no currency format
        sign = "-" if cents < 0 else ""
        return f"{sign}${abs(cents) / 100:,.2f}"


def parse_money(text: str) -> Optional[int]:
    """Parses "250", "250.00", "$250" into cents. Returns None on junk."""
    cleaned = "".join(c for c in text if c.isdigit() or c in ".-")
    try:
        value = float(cleaned)
    except ValueError:
        return None
    return rounded(value * 100) if math.isfinite(value) else None


def _duration_field(text: str) -> Optional[float]:
    trimmed = text.strip()
    if not trimmed:
        return 0.0  # blank counts as zero, so either field can be left empty
    try:
        value = float(trimmed)
    except ValueError:
        return None
    return value if value >= 0 and math.isfinite(value) else None


def parse_duration(hours: str, minutes: str) -> Optional[int]:
    """"1" hour and "45" minutes is 6300 seconds. None if a field is unreadable."""
    hour_value, minute_value = _duration_field(hours), _duration_field(minutes)
    if hour_value is None or minute_value is None:
        return None
    return rounded(hour_value * 3600 + minute_value * 60)


def fmt_day_label(value: datetime) -> str:
    return value.strftime("%a %b %-d")


def fmt_short_date(value: datetime) -> str:
    return value.strftime("%b %-d, %Y")


def fmt_compact_date(value: datetime) -> str:
    return value.strftime("%b %-d")


def fmt_time(value: datetime) -> str:
    return value.strftime("%-I:%M %p")


def fmt_range(period: DateRange, kind: str) -> str:
    if kind == DAY:
        return fmt_short_date(period.start)
    return f"{fmt_compact_date(period.start)} – {fmt_short_date(period.last_day)}"


# MARK: - Schema


MIGRATIONS = [
    # v1 — clients, projects, entries, settings, invoices
    """
    CREATE TABLE clients (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        name              TEXT    NOT NULL,
        hourly_rate_cents INTEGER NOT NULL DEFAULT 0,
        address           TEXT    NOT NULL DEFAULT '',
        notes             TEXT    NOT NULL DEFAULT '',
        archived          INTEGER NOT NULL DEFAULT 0,
        created_at        INTEGER NOT NULL
    );

    CREATE TABLE projects (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        client_id         INTEGER NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
        name              TEXT    NOT NULL,
        hourly_rate_cents INTEGER,          -- NULL means inherit the client rate
        archived          INTEGER NOT NULL DEFAULT 0,
        created_at        INTEGER NOT NULL
    );

    CREATE TABLE entries (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id   INTEGER NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
        started_at  INTEGER NOT NULL,        -- unix seconds
        ended_at    INTEGER,                 -- NULL while the timer is running
        note        TEXT    NOT NULL DEFAULT '',
        invoice_id  INTEGER REFERENCES invoices(id) ON DELETE SET NULL,
        created_at  INTEGER NOT NULL
    );

    CREATE TABLE invoices (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        client_id    INTEGER NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
        number       TEXT    NOT NULL,
        issued_at    INTEGER NOT NULL,
        period_start INTEGER NOT NULL,
        period_end   INTEGER NOT NULL,
        total_cents  INTEGER NOT NULL,
        seconds      INTEGER NOT NULL,
        file_path    TEXT    NOT NULL DEFAULT ''
    );

    CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE INDEX idx_entries_started ON entries(started_at);
    CREATE INDEX idx_entries_project  ON entries(project_id);
    CREATE INDEX idx_entries_invoice ON entries(invoice_id);
    CREATE INDEX idx_projects_client  ON projects(client_id);
    -- Partial index: looking up what's currently running stays O(running), not O(all entries).
    CREATE INDEX idx_entries_running ON entries(id) WHERE ended_at IS NULL;
    """
]


# MARK: - Store


def _plural_entries(count: int) -> str:
    return f"{count} time entr{'y' if count == 1 else 'ies'}"


class Store:
    """Every read and write the app performs."""

    _ENTRY_SELECT = """
        SELECT e.id, e.project_id, e.started_at, e.ended_at, e.note, e.invoice_id,
               m.name AS project_name,
               c.id   AS client_id,
               c.name AS client_name,
               COALESCE(m.hourly_rate_cents, c.hourly_rate_cents) AS rate_cents
        FROM entries e
        JOIN projects m ON m.id = e.project_id
        JOIN clients c ON c.id = m.client_id
        """

    def __init__(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True)
        self.path = str(directory / "billabletimer.sqlite3")
        try:
            # autocommit mode: transactions below are explicit, as in the Swift wrapper.
            self.db = sqlite3.connect(self.path, isolation_level=None)
            self.db.row_factory = sqlite3.Row
            self.db.execute("PRAGMA journal_mode = WAL")
            self.db.execute("PRAGMA foreign_keys = ON")
            self.db.execute("PRAGMA busy_timeout = 3000")
            self._migrate()
        except sqlite3.Error as error:
            raise DBError(f"Could not open database at {self.path}: {error}") from error

    def _migrate(self) -> None:
        current = self.db.execute("PRAGMA user_version").fetchone()[0]
        for version in range(current, len(MIGRATIONS)):
            try:
                self.db.executescript(
                    f"BEGIN;\n{MIGRATIONS[version]}\nPRAGMA user_version = {version + 1};\nCOMMIT;"
                )
            except sqlite3.Error:
                if self.db.in_transaction:
                    self.db.execute("ROLLBACK")
                raise

    def _transaction(self):
        return _Transaction(self.db)

    @staticmethod
    def _now() -> int:
        return int(datetime.now().timestamp())

    # Clients

    def clients(self, include_archived: bool = False) -> list[Client]:
        where = "" if include_archived else "WHERE archived = 0"
        rows = self.db.execute(
            f"SELECT * FROM clients {where} ORDER BY archived, name COLLATE NOCASE"
        )
        return [Client.from_row(r) for r in rows]

    def create_client(self, name: str, rate_cents: int, address: str = "", notes: str = "") -> int:
        return self.db.execute(
            "INSERT INTO clients (name, hourly_rate_cents, address, notes, created_at) VALUES (?, ?, ?, ?, ?)",
            (name, rate_cents, address, notes, self._now()),
        ).lastrowid

    def update_client(self, client: Client) -> None:
        self.db.execute(
            "UPDATE clients SET name = ?, hourly_rate_cents = ?, address = ?, notes = ?, archived = ? WHERE id = ?",
            (client.name, client.hourly_rate_cents, client.address, client.notes,
             int(client.archived), client.id),
        )

    def delete_client(self, client_id: int) -> None:
        """Refuses to delete a client that still has time on the books."""
        count = self.db.execute(
            """SELECT COUNT(*) FROM entries e JOIN projects m ON m.id = e.project_id
               WHERE m.client_id = ?""",
            (client_id,),
        ).fetchone()[0]
        if count:
            raise DBError(
                f"This client has {_plural_entries(count)}. Archive it instead of "
                "deleting, so the billing history stays intact."
            )
        with self._transaction():
            self.db.execute("DELETE FROM projects WHERE client_id = ?", (client_id,))
            self.db.execute("DELETE FROM clients WHERE id = ?", (client_id,))

    # Projects

    def projects(self, include_archived: bool = False) -> list[Project]:
        where = "" if include_archived else "WHERE m.archived = 0 AND c.archived = 0"
        rows = self.db.execute(
            f"""SELECT m.id, m.client_id, m.name, m.hourly_rate_cents, m.archived,
                       c.name AS client_name, c.hourly_rate_cents AS client_rate_cents
                FROM projects m JOIN clients c ON c.id = m.client_id
                {where}
                ORDER BY c.name COLLATE NOCASE, m.name COLLATE NOCASE"""
        )
        return [Project.from_row(r) for r in rows]

    def create_project(self, client_id: int, name: str, rate_cents: Optional[int]) -> int:
        return self.db.execute(
            "INSERT INTO projects (client_id, name, hourly_rate_cents, created_at) VALUES (?, ?, ?, ?)",
            (client_id, name, rate_cents, self._now()),
        ).lastrowid

    def update_project(self, project: Project) -> None:
        self.db.execute(
            "UPDATE projects SET name = ?, hourly_rate_cents = ?, archived = ? WHERE id = ?",
            (project.name, project.hourly_rate_cents, int(project.archived), project.id),
        )

    def delete_project(self, project_id: int) -> None:
        count = self.db.execute(
            "SELECT COUNT(*) FROM entries WHERE project_id = ?", (project_id,)
        ).fetchone()[0]
        if count:
            raise DBError(f"This project has {_plural_entries(count)}. Archive it instead of deleting.")
        self.db.execute("DELETE FROM projects WHERE id = ?", (project_id,))

    # Timers

    def start_timer(self, project_id: int, note: str = "") -> int:
        """Concurrent timers are allowed by design, so this never stops anything."""
        stamp = self._now()
        return self.db.execute(
            "INSERT INTO entries (project_id, started_at, note, created_at) VALUES (?, ?, ?, ?)",
            (project_id, stamp, note, stamp),
        ).lastrowid

    def stop_timer(self, entry_id: int) -> None:
        # MAX guards the pathological case of a clock change making end < start.
        self.db.execute(
            "UPDATE entries SET ended_at = MAX(?, started_at) WHERE id = ? AND ended_at IS NULL",
            (self._now(), entry_id),
        )

    def stop_all_timers(self) -> None:
        self.db.execute(
            "UPDATE entries SET ended_at = MAX(?, started_at) WHERE ended_at IS NULL", (self._now(),)
        )

    def cancel_timer(self, entry_id: int) -> None:
        """Discards a running timer without recording any time."""
        self.db.execute("DELETE FROM entries WHERE id = ? AND ended_at IS NULL", (entry_id,))

    def running_entries(self) -> list[Entry]:
        rows = self.db.execute(f"{self._ENTRY_SELECT} WHERE e.ended_at IS NULL ORDER BY e.started_at")
        return [Entry.from_row(r) for r in rows]

    # Entries

    def entries(self, period: DateRange) -> list[Entry]:
        """Attributed by start time, so an entry is never split between periods."""
        rows = self.db.execute(
            f"{self._ENTRY_SELECT} WHERE e.started_at >= ? AND e.started_at < ? ORDER BY e.started_at DESC",
            (_stamp(period.start), _stamp(period.end)),
        )
        return [Entry.from_row(r) for r in rows]

    def entry(self, entry_id: int) -> Optional[Entry]:
        row = self.db.execute(f"{self._ENTRY_SELECT} WHERE e.id = ?", (entry_id,)).fetchone()
        return Entry.from_row(row) if row else None

    def add_manual_entry(self, project_id: int, start: datetime, end: datetime, note: str) -> int:
        start_stamp = _stamp(start)
        return self.db.execute(
            "INSERT INTO entries (project_id, started_at, ended_at, note, created_at) VALUES (?, ?, ?, ?, ?)",
            (project_id, start_stamp, max(start_stamp, _stamp(end)), note, self._now()),
        ).lastrowid

    def _require_uninvoiced(self, entry_id: int, verb: str) -> None:
        # Invoiced entries are locked so a sent invoice can't stop matching its time.
        existing = self.entry(entry_id)
        if existing and existing.invoice_id is not None:
            raise DBError(f"This entry is already on an invoice. Delete the invoice first if you need to {verb} it.")

    def update_entry(self, entry_id: int, project_id: int, start: datetime,
                     end: Optional[datetime], note: str) -> None:
        self._require_uninvoiced(entry_id, "change")
        start_stamp = _stamp(start)
        end_value = None if end is None else max(start_stamp, _stamp(end))
        self.db.execute(
            "UPDATE entries SET project_id = ?, started_at = ?, ended_at = ?, note = ? WHERE id = ?",
            (project_id, start_stamp, end_value, note, entry_id),
        )

    def delete_entry(self, entry_id: int) -> None:
        self._require_uninvoiced(entry_id, "remove")
        self.db.execute("DELETE FROM entries WHERE id = ?", (entry_id,))

    # Invoicing

    def billable_entries(self, client_id: int, period: DateRange) -> list[Entry]:
        """Stopped, not-yet-invoiced entries for one client in a period."""
        rows = self.db.execute(
            f"""{self._ENTRY_SELECT}
                WHERE c.id = ? AND e.invoice_id IS NULL AND e.ended_at IS NOT NULL
                  AND e.started_at >= ? AND e.started_at < ?
                ORDER BY e.started_at""",
            (client_id, _stamp(period.start), _stamp(period.end)),
        )
        return [Entry.from_row(r) for r in rows]

    def record_invoice(self, client_id: int, number: str, period_start: datetime,
                       period_end: datetime, entries: list[Entry], total_cents: int,
                       seconds: int, file_path: str) -> int:
        """One transaction, so entries can't be marked billed on a missing invoice."""
        with self._transaction():
            invoice_id = self.db.execute(
                """INSERT INTO invoices (client_id, number, issued_at, period_start, period_end,
                                         total_cents, seconds, file_path)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (client_id, number, self._now(), _stamp(period_start), _stamp(period_end),
                 total_cents, seconds, file_path),
            ).lastrowid
            for entry in entries:
                self.db.execute("UPDATE entries SET invoice_id = ? WHERE id = ?", (invoice_id, entry.id))
        return invoice_id

    def invoices(self) -> list[Invoice]:
        rows = self.db.execute(
            """SELECT i.*, c.name AS client_name,
                      (SELECT GROUP_CONCAT(name, ' + ') FROM (
                          SELECT DISTINCT other.name FROM entries e
                          JOIN projects m ON m.id = e.project_id
                          JOIN clients other ON other.id = m.client_id
                          WHERE e.invoice_id = i.id AND other.id <> i.client_id
                          ORDER BY other.name COLLATE NOCASE
                      )) AS other_clients
               FROM invoices i
               JOIN clients c ON c.id = i.client_id ORDER BY i.issued_at DESC"""
        )
        return [Invoice.from_row(r) for r in rows]

    def delete_invoice(self, invoice_id: int) -> None:
        """Releases the invoice's entries back into the billable pool."""
        with self._transaction():
            self.db.execute("UPDATE entries SET invoice_id = NULL WHERE invoice_id = ?", (invoice_id,))
            self.db.execute("DELETE FROM invoices WHERE id = ?", (invoice_id,))

    # Settings

    def load_settings(self) -> AppSettings:
        values = {r["key"]: r["value"] for r in self.db.execute("SELECT key, value FROM settings")}
        settings = AppSettings()

        def as_int(key: str, fallback: int) -> int:
            try:
                return int(values[key])
            except (KeyError, ValueError):
                return fallback

        settings.business_name = values.get("businessName", settings.business_name)
        settings.business_address = values.get("businessAddress", settings.business_address)
        settings.business_email = values.get("businessEmail", settings.business_email)
        settings.invoice_terms = values.get("invoiceTerms", settings.invoice_terms)
        settings.invoice_prefix = values.get("invoicePrefix", settings.invoice_prefix)
        settings.next_invoice_number = as_int("nextInvoiceNumber", settings.next_invoice_number)
        settings.first_weekday = as_int("firstWeekday", settings.first_weekday)
        try:
            settings.period_anchor = datetime.fromtimestamp(float(values["periodAnchor"]))
        except (KeyError, ValueError):
            pass
        return settings

    def save_settings(self, settings: AppSettings) -> None:
        pairs = [
            ("businessName", settings.business_name),
            ("businessAddress", settings.business_address),
            ("businessEmail", settings.business_email),
            ("invoiceTerms", settings.invoice_terms),
            ("invoicePrefix", settings.invoice_prefix),
            ("nextInvoiceNumber", str(settings.next_invoice_number)),
            ("firstWeekday", str(settings.first_weekday)),
            ("periodAnchor", str(settings.period_anchor.timestamp())),
        ]
        with self._transaction():
            self.db.executemany(
                "INSERT INTO settings (key, value) VALUES (?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                pairs,
            )


class _Transaction:
    def __init__(self, db: sqlite3.Connection):
        self.db = db

    def __enter__(self):
        self.db.execute("BEGIN")

    def __exit__(self, exc_type, exc, tb):
        self.db.execute("COMMIT" if exc_type is None else "ROLLBACK")
        return False


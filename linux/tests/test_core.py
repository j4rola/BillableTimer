"""Run from `linux/` with: python3 -m unittest discover tests"""

import locale
import sqlite3
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

from billabletimer import core, invoice_pdf
from billabletimer.core import AppSettings, DBError, Store


def setUpModule():
    locale.setlocale(locale.LC_ALL, "en_US.UTF-8")


class Rounding(unittest.TestCase):
    def test_half_rounds_away_from_zero_like_swift(self):
        self.assertEqual(core.rounded(2.5), 3)  # Python's round() gives 2
        self.assertEqual(core.rounded(0.5), 1)
        self.assertEqual(core.rounded(-2.5), -3)

    def test_exact_half_cent_entry_rounds_up(self):
        store = Store(Path(tempfile.mkdtemp()))
        project = store.create_project(store.create_client("C", 5000), "P", None)
        start = datetime(2026, 3, 2, 9, 0, 0)
        # 81 seconds at $50.00/h is exactly 112.5 cents; round() would give 112.
        store.add_manual_entry(project, start, start + timedelta(seconds=81), "")
        entry = store.entries(core.day_range(start))[0]
        self.assertEqual(entry.amount_cents(start), 113)


class Parsing(unittest.TestCase):
    def test_money(self):
        self.assertEqual(core.parse_money("250"), 25000)
        self.assertEqual(core.parse_money("$250.50"), 25050)
        self.assertEqual(core.parse_money("1,250.00"), 125000)
        self.assertIsNone(core.parse_money("junk"))
        self.assertIsNone(core.parse_money(""))

    def test_duration(self):
        self.assertEqual(core.parse_duration("1", "45"), 6300)
        self.assertEqual(core.parse_duration("", "45"), 2700)
        self.assertEqual(core.parse_duration("2", ""), 7200)
        self.assertEqual(core.parse_duration("0", "90"), 5400)
        self.assertEqual(core.parse_duration("1.5", ""), 5400)
        self.assertEqual(core.parse_duration("", ""), 0)
        self.assertIsNone(core.parse_duration("abc", "1"))
        self.assertIsNone(core.parse_duration("-1", "1"))
        self.assertIsNone(core.parse_duration("inf", "1"))

    def test_formats(self):
        self.assertEqual(core.fmt_clock(7531), "2:05:31")
        self.assertEqual(core.fmt_duration(7531), "2h 05m")
        self.assertEqual(core.fmt_duration(300), "5m")
        self.assertEqual(core.fmt_hours(6300), "1.75")


class Periods(unittest.TestCase):
    def test_week_monday_and_sunday_start(self):
        wednesday = datetime(2026, 3, 4, 15, 0)
        self.assertEqual(core.week_range(wednesday, 2).start, datetime(2026, 3, 2))
        self.assertEqual(core.week_range(wednesday, 1).start, datetime(2026, 3, 1))
        sunday = datetime(2026, 3, 8, 15, 0)
        self.assertEqual(core.week_range(sunday, 2).start, datetime(2026, 3, 2))
        self.assertEqual(core.week_range(sunday, 1).start, datetime(2026, 3, 8))

    def test_two_weeks_tile_both_directions(self):
        anchor = datetime(2026, 3, 2)
        self.assertEqual(core.two_week_range(datetime(2026, 3, 15), anchor).start, anchor)
        self.assertEqual(core.two_week_range(datetime(2026, 3, 16), anchor).start, datetime(2026, 3, 16))
        self.assertEqual(core.two_week_range(datetime(2026, 3, 1), anchor).start, datetime(2026, 2, 16))

    def test_days_across_dst_stay_on_midnight(self):
        period = core.week_range(datetime(2026, 3, 8), 1)  # US spring-forward week
        days = core.days_in(period)
        self.assertEqual(len(days), 7)
        self.assertTrue(all(d.hour == 0 for d in days))

    def test_range_label(self):
        period = core.two_week_range(datetime(2026, 3, 3), datetime(2026, 3, 2))
        self.assertEqual(core.fmt_range(period, core.TWO_WEEKS), "Mar 2 – Mar 15, 2026")


class StoreBehaviour(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.store = Store(self.dir)
        self.client = self.store.create_client("Acme", 25000, "1 Main St")
        self.project = self.store.create_project(self.client, "Merger", None)
        self.start = datetime(2026, 3, 2, 22, 0)

    def test_rate_inheritance_and_override(self):
        other = self.store.create_project(self.client, "Special", 30000)
        rates = {p.name: p.effective_rate_cents for p in self.store.projects()}
        self.assertEqual(rates, {"Merger": 25000, "Special": 30000})
        self.assertEqual(other, self.store.projects()[1].id)

    def test_concurrent_timers_and_stop(self):
        first = self.store.start_timer(self.project)
        self.store.start_timer(self.project)
        self.assertEqual(len(self.store.running_entries()), 2)
        self.store.stop_timer(first)
        self.assertEqual(len(self.store.running_entries()), 1)
        self.store.stop_all_timers()
        self.assertEqual(self.store.running_entries(), [])

    def test_entry_counts_toward_start_day(self):
        self.store.add_manual_entry(self.project, self.start, self.start + timedelta(hours=3), "")
        self.assertEqual(len(self.store.entries(core.day_range(self.start))), 1)
        self.assertEqual(len(self.store.entries(core.day_range(self.start + timedelta(days=1)))), 0)

    def test_invoice_locks_entries_and_delete_releases_them(self):
        entry_id = self.store.add_manual_entry(self.project, self.start, self.start + timedelta(hours=1), "")
        period = core.day_range(self.start)
        billable = self.store.billable_entries(self.client, period)
        invoice = self.store.record_invoice(self.client, "INV-0001", period.start, period.last_day,
                                            billable, 25000, 3600, "/tmp/x.pdf")
        self.assertEqual(self.store.billable_entries(self.client, period), [])
        with self.assertRaises(DBError):
            self.store.delete_entry(entry_id)
        with self.assertRaises(DBError):
            self.store.update_entry(entry_id, self.project, self.start, self.start, "")
        self.store.delete_invoice(invoice)
        self.assertEqual(len(self.store.billable_entries(self.client, period)), 1)

    def test_combined_invoice_locks_all_clients_and_delete_releases_them(self):
        other = self.store.create_client("Globex", 10000)
        other_project = self.store.create_project(other, "Filing", None)
        self.store.add_manual_entry(self.project, self.start, self.start + timedelta(hours=1), "")
        self.store.add_manual_entry(other_project, self.start, self.start + timedelta(hours=1), "")
        period = core.day_range(self.start)
        entries = (self.store.billable_entries(self.client, period)
                   + self.store.billable_entries(other, period))
        invoice_id = self.store.record_invoice(self.client, "INV-0001", period.start, period.last_day,
                                               entries, 35000, 7200, "")
        invoice = self.store.invoices()[0]
        self.assertEqual(invoice.client_label, "Acme + Globex")
        self.assertEqual(self.store.billable_entries(other, period), [])
        self.store.delete_invoice(invoice_id)
        self.assertEqual(len(self.store.billable_entries(other, period)), 1)

    def test_single_client_invoice_has_plain_label(self):
        self.store.add_manual_entry(self.project, self.start, self.start + timedelta(hours=1), "")
        period = core.day_range(self.start)
        self.store.record_invoice(self.client, "INV-0001", period.start, period.last_day,
                                  self.store.billable_entries(self.client, period), 25000, 3600, "")
        self.assertEqual(self.store.invoices()[0].client_label, "Acme")

    def test_delete_refused_while_time_exists(self):
        self.store.add_manual_entry(self.project, self.start, self.start, "")
        with self.assertRaises(DBError):
            self.store.delete_client(self.client)
        with self.assertRaises(DBError):
            self.store.delete_project(self.project)

    def test_running_timer_is_not_billable(self):
        self.store.start_timer(self.project)
        self.assertEqual(self.store.billable_entries(self.client, core.day_range(datetime.now())), [])

    def test_settings_round_trip(self):
        settings = AppSettings(business_name="Me", next_invoice_number=7, first_weekday=1,
                               period_anchor=datetime(2026, 3, 2))
        self.store.save_settings(settings)
        loaded = Store(self.dir).load_settings()
        self.assertEqual(loaded, settings)

    def test_failed_transaction_rolls_back(self):
        with self.assertRaises(sqlite3.Error):
            with self.store._transaction():
                self.store.db.execute("DELETE FROM clients WHERE id = 999")
                self.store.db.execute("INSERT INTO projects (client_id, name, created_at) VALUES (424242, 'x', 0)")
                self.store.db.execute("INSERT INTO nonexistent VALUES (1)")
        self.assertFalse(self.store.db.in_transaction)

    def test_opens_database_written_by_macos_schema(self):
        """user_version 1 with the Swift app's data must load with no migration."""
        directory = Path(tempfile.mkdtemp())
        db = sqlite3.connect(directory / "billabletimer.sqlite3")
        db.executescript(core.MIGRATIONS[0])
        db.execute("PRAGMA user_version = 1")
        db.execute("INSERT INTO clients (name, created_at) VALUES ('Mac', 0)")
        db.execute("INSERT INTO settings VALUES ('periodAnchor', '1772431200.0')")
        db.commit()
        db.close()
        store = Store(directory)
        self.assertEqual(store.clients()[0].name, "Mac")
        self.assertEqual(store.load_settings().period_anchor, datetime.fromtimestamp(1772431200))


class Invoice(unittest.TestCase):
    def render(self, count, note="Reviewed documents"):
        store = Store(Path(tempfile.mkdtemp()))
        client_id = store.create_client("Acme Corp", 25000, "1 Main St\nSpringfield")
        project = store.create_project(client_id, "Merger", None)
        start = datetime(2026, 3, 2, 9, 0)
        for i in range(count):
            store.add_manual_entry(project, start + timedelta(minutes=i), start + timedelta(minutes=i + 90), note)
        period = core.day_range(start)
        entries = store.billable_entries(client_id, period)
        data = invoice_pdf.Input(
            AppSettings(business_name="Froula Law", business_email="a@b.c"),
            store.clients()[0], "INV-0001", start, period, entries,
        )
        path = str(Path(tempfile.mkdtemp()) / "invoice.pdf")
        invoice_pdf.render(data, path)
        return path, data

    def text(self, path):
        return subprocess.run(["pdftotext", "-layout", path, "-"], capture_output=True, text=True, check=True).stdout

    def test_single_page_contents(self):
        path, data = self.render(3)
        text = self.text(path)
        for expected in ("INVOICE", "INV-0001", "Froula Law", "Acme Corp", "Springfield",
                         "Merger", "4.50", "$1,125.00", "Payable within 30 days."):
            self.assertIn(expected, text)
        self.assertNotIn("Page 1 of", text)
        self.assertEqual(data.total_cents, 112500)

    def test_paginates_with_footer(self):
        path, _ = self.render(80)
        text = self.text(path)
        self.assertIn("Page 1 of", text)
        self.assertEqual(text.count("AMOUNT DUE"), 1)  # totals only on the last page

    def test_combined_invoice_names_each_client_and_sums_rates(self):
        store = Store(Path(tempfile.mkdtemp()))
        first = store.create_client("Acme", 25000)
        second = store.create_client("Globex", 10000)
        start = datetime(2026, 3, 2, 9, 0)
        for client in (first, second):
            project = store.create_project(client, "Work", None)
            store.add_manual_entry(project, start, start + timedelta(hours=1), "")
        period = core.day_range(start)
        entries = store.billable_entries(first, period) + store.billable_entries(second, period)
        data = invoice_pdf.Input(AppSettings(), store.clients()[0], "INV-0001", start, period, entries)
        path = str(Path(tempfile.mkdtemp()) / "invoice.pdf")
        invoice_pdf.render(data, path)
        text = self.text(path)
        self.assertIn("Acme › Work", text)
        self.assertIn("Globex › Work", text)
        self.assertIn("$350.00", text)

    def test_failure_leaves_no_partial_file(self):
        path, data = self.render(1)
        target = Path(path).parent / "missing" / "x.pdf"
        with self.assertRaises(DBError):
            invoice_pdf.render(data, str(target))
        self.assertFalse(target.parent.exists())


if __name__ == "__main__":
    unittest.main()

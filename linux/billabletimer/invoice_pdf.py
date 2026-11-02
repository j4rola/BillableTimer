"""Renders a client-ready invoice to PDF with cairo and Pango.

Same page geometry as the Swift `InvoicePDF`, with CoreGraphics swapped out. All
layout keeps that file's y-up coordinates so the two read side by side; `_draw`
is the one place that converts to cairo's y-down space.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime

import cairo
import gi

gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Pango, PangoCairo  # noqa: E402

from . import core  # noqa: E402
from .core import AppSettings, Client, DateRange, DBError, Entry  # noqa: E402

PAGE_WIDTH, PAGE_HEIGHT = 612.0, 792.0  # US Letter
MARGIN = 54.0
FOOTER_RESERVE = 34.0
DRAW_SLACK = 5.0
ADDRESS_WIDTH = 240.0
TABLE_HEADER_HEIGHT = 22.0

LEFT, RIGHT = Pango.Alignment.LEFT, Pango.Alignment.RIGHT

# (x, width); 62 + 104 + 168 + 50 + 56 + 64 = 504 = content width
COL_DATE = (54.0, 62.0)
COL_PROJECT = (116.0, 104.0)
COL_DESCRIPTION = (220.0, 168.0)
COL_HOURS = (388.0, 50.0)
COL_RATE = (438.0, 56.0)
COL_AMOUNT = (494.0, 64.0)

FAMILY = "Liberation Sans, Noto Sans, DejaVu Sans, Sans"
TITLE = (26.0, Pango.Weight.LIGHT)
HEADING = (11.0, Pango.Weight.SEMIBOLD)
LABEL = (8.0, Pango.Weight.SEMIBOLD)
BODY = (9.5, Pango.Weight.NORMAL)
CELL = (9.0, Pango.Weight.NORMAL)
TOTAL = (13.0, Pango.Weight.SEMIBOLD)

INK = (0.0, 0.0, 0.0)
MUTED = (0.42, 0.42, 0.42)
RULE = (0.78, 0.78, 0.78)
ROW_RULE = (0.90, 0.90, 0.90)


@dataclass
class Input:
    settings: AppSettings
    client: Client
    number: str
    issued_at: datetime
    period: DateRange
    entries: list[Entry]

    @property
    def spans_clients(self) -> bool:
        return len({e.client_id for e in self.entries}) > 1

    @property
    def total_seconds(self) -> int:
        return sum(e.seconds(e.ended_at or datetime.now()) for e in self.entries)

    @property
    def total_cents(self) -> int:
        return sum(e.amount_cents(e.ended_at or datetime.now()) for e in self.entries)


@dataclass
class _Row:
    date: str
    project: str
    description: str
    hours: str
    rate: str
    amount: str
    height: float


@dataclass
class _Header:
    from_text: str
    from_height: float
    to_text: str
    to_height: float
    total: float


class _Renderer:
    def __init__(self, ctx: cairo.Context, data: Input):
        self.ctx = ctx
        self.data = data

    def _layout(self, text: str, font, width: float, alignment, tracking: float = 0) -> Pango.Layout:
        layout = PangoCairo.create_layout(self.ctx)
        description = Pango.FontDescription(FAMILY)
        # Absolute size: one Pango unit is one PDF point, whatever the screen DPI.
        description.set_absolute_size(font[0] * Pango.SCALE)
        description.set_weight(font[1])
        layout.set_font_description(description)
        layout.set_width(int(width * Pango.SCALE))
        layout.set_wrap(Pango.WrapMode.WORD_CHAR)
        layout.set_alignment(alignment)
        layout.set_spacing(1 * Pango.SCALE)
        if tracking:
            attributes = Pango.AttrList()
            attributes.insert(Pango.attr_letter_spacing_new(int(tracking * Pango.SCALE)))
            layout.set_attributes(attributes)
        layout.set_text(text, -1)
        return layout

    def height(self, text: str, font, width: float) -> float:
        return float(self._layout(text, font, width, LEFT).get_pixel_size()[1])

    def draw(self, text: str, font, x: float, width: float, top_y: float,
             color=INK, alignment=LEFT, tracking: float = 0.0) -> None:
        """Draws text with its top edge at `top_y` in y-up page coordinates."""
        if not text:
            return
        layout = self._layout(text, font, width, alignment, tracking)
        self.ctx.save()
        self.ctx.set_source_rgb(*color)
        self.ctx.move_to(x, PAGE_HEIGHT - top_y)
        PangoCairo.show_layout(self.ctx, layout)
        self.ctx.restore()

    def rule(self, y: float, color=RULE, width: float = 0.5) -> None:
        self.ctx.save()
        self.ctx.set_source_rgb(*color)
        self.ctx.set_line_width(width)
        self.ctx.move_to(MARGIN, PAGE_HEIGHT - y)
        self.ctx.line_to(PAGE_WIDTH - MARGIN, PAGE_HEIGHT - y)
        self.ctx.stroke()
        self.ctx.restore()

    # Rows

    def build_rows(self) -> list[_Row]:
        rows = []
        for entry in self.data.entries:
            end = entry.ended_at or datetime.now()
            description = entry.note.strip() or "—"
            date = core.fmt_compact_date(entry.started_at)
            # On a combined invoice the project alone wouldn't say whose time it is.
            project = (f"{entry.client_name} › {entry.project_name}" if self.data.spans_clients
                       else entry.project_name)
            # The row is as tall as its tallest wrapping cell.
            tallest = max(
                self.height(date, CELL, COL_DATE[1]),
                self.height(project, CELL, COL_PROJECT[1]),
                self.height(description, CELL, COL_DESCRIPTION[1]),
            )
            rows.append(_Row(
                date, project, description,
                core.fmt_hours(entry.seconds(end)),
                core.fmt_money(entry.rate_cents),
                core.fmt_money(entry.amount_cents(end)),
                tallest + 9,  # 9pt of breathing room per row
            ))
        return rows

    # Header

    def header_metrics(self) -> _Header:
        settings, client = self.data.settings, self.data.client
        from_text = "\n".join(
            t for t in (settings.business_name, settings.business_address, settings.business_email) if t
        )
        to_text = "\n".join(t for t in (client.name, client.address) if t)
        # Floors keep the layout from collapsing when a block is short or empty.
        from_height = max(self.height(from_text or "—", BODY, ADDRESS_WIDTH), 31)
        to_height = max(self.height(to_text or "—", BODY, ADDRESS_WIDTH), 17)
        # 34 title + 13 label + from + 26 gap + 13 label + to + 30 gap, plus the
        # slack each drawn block hangs below its measured height.
        return _Header(from_text, from_height, to_text, to_height,
                       116 + from_height + to_height + DRAW_SLACK * 2)

    def draw_header(self, top_y: float) -> float:
        metrics = self.header_metrics()
        data = self.data
        y = top_y
        self.draw("INVOICE", TITLE, MARGIN, 260, y, tracking=1.5)

        period = (f"{core.fmt_compact_date(data.period.start)} – "
                  f"{core.fmt_compact_date(data.period.last_day)}")
        meta_y = y - 2
        for label, value in (("INVOICE NO.", data.number),
                             ("DATE", core.fmt_short_date(data.issued_at)),
                             ("PERIOD", period)):
            self.draw(label, LABEL, PAGE_WIDTH - MARGIN - 200, 90, meta_y,
                      color=MUTED, alignment=RIGHT, tracking=0.6)
            self.draw(value, BODY, PAGE_WIDTH - MARGIN - 104, 104, meta_y, alignment=RIGHT)
            meta_y -= 15

        y -= 34
        self.draw("FROM", LABEL, MARGIN, ADDRESS_WIDTH, y, color=MUTED, tracking=0.6)
        self.draw(metrics.from_text or "—", BODY, MARGIN, ADDRESS_WIDTH, y - 13)
        y -= 13 + metrics.from_height + DRAW_SLACK + 26

        self.draw("BILL TO", LABEL, MARGIN, ADDRESS_WIDTH, y, color=MUTED, tracking=0.6)
        self.draw(metrics.to_text or "—", BODY, MARGIN, ADDRESS_WIDTH, y - 13)
        y -= 13 + metrics.to_height + DRAW_SLACK + 30
        return y

    # Table

    def draw_table_header(self, top_y: float) -> float:
        self.rule(top_y, INK, 0.8)
        y = top_y - 6
        for text, column, alignment in (("DATE", COL_DATE, LEFT), ("PROJECT", COL_PROJECT, LEFT),
                                        ("DESCRIPTION", COL_DESCRIPTION, LEFT), ("HOURS", COL_HOURS, RIGHT),
                                        ("RATE", COL_RATE, RIGHT), ("AMOUNT", COL_AMOUNT, RIGHT)):
            self.draw(text, LABEL, column[0], column[1], y, color=MUTED, alignment=alignment, tracking=0.6)
        return top_y - TABLE_HEADER_HEIGHT

    def draw_row(self, row: _Row, top_y: float) -> None:
        y = top_y - 3
        self.draw(row.date, CELL, *COL_DATE, y, color=MUTED)
        self.draw(row.project, CELL, *COL_PROJECT, y)
        self.draw(row.description, CELL, *COL_DESCRIPTION, y)
        self.draw(row.hours, CELL, *COL_HOURS, y, alignment=RIGHT)
        self.draw(row.rate, CELL, *COL_RATE, y, color=MUTED, alignment=RIGHT)
        self.draw(row.amount, CELL, *COL_AMOUNT, y, alignment=RIGHT)

    def draw_totals(self, top_y: float) -> None:
        data = self.data
        value_x, value_width = COL_RATE[0], COL_RATE[1] + COL_AMOUNT[1]
        y = top_y
        self.rule(y, INK, 0.8)
        y -= 12
        self.draw("Total hours", BODY, COL_DESCRIPTION[0], 218, y, color=MUTED, alignment=RIGHT)
        self.draw(core.fmt_hours(data.total_seconds), BODY, value_x, value_width, y, alignment=RIGHT)
        y -= 20
        self.draw("AMOUNT DUE", HEADING, COL_DESCRIPTION[0], 218, y, alignment=RIGHT)
        self.draw(core.fmt_money(data.total_cents), TOTAL, value_x, value_width, y + 3, alignment=RIGHT)
        y -= 30
        if data.settings.invoice_terms:
            self.draw(data.settings.invoice_terms, BODY, MARGIN, 300, y, color=MUTED)

    def draw_footer(self, page: int, page_count: int) -> None:
        settings = self.data.settings
        y = MARGIN - 6
        self.draw(settings.business_name or self.data.client.name, CELL, MARGIN, 300, y, color=MUTED)
        if page_count > 1:
            self.draw(f"Page {page} of {page_count}", CELL, PAGE_WIDTH - MARGIN - 140, 140, y,
                      color=MUTED, alignment=RIGHT)

    # Pages

    def paginate(self, rows: list[_Row]) -> list[list[_Row]]:
        """Paginates first, so the footer can honestly say "Page 1 of 3"."""
        first_top = PAGE_HEIGHT - MARGIN - self.header_metrics().total
        later_top = PAGE_HEIGHT - MARGIN
        pages: list[list[_Row]] = []
        current: list[_Row] = []
        cursor = first_top - TABLE_HEADER_HEIGHT
        for row in rows:
            if cursor - row.height < MARGIN + FOOTER_RESERVE and current:
                pages.append(current)
                current = []
                cursor = later_top - TABLE_HEADER_HEIGHT
            current.append(row)
            cursor -= row.height
        pages.append(current)
        # The totals block needs room on the final page; otherwise it gets its own.
        if cursor - 96 < MARGIN + FOOTER_RESERVE:
            pages.append([])
        return pages

    def render(self) -> None:
        pages = self.paginate(self.build_rows())
        for index, page_rows in enumerate(pages):
            y = PAGE_HEIGHT - MARGIN
            if index == 0:
                y = self.draw_header(y)
            y = self.draw_table_header(y)
            for row in page_rows:
                self.draw_row(row, y)
                y -= row.height
                self.rule(y + 2, ROW_RULE, 0.4)
            if index == len(pages) - 1:
                self.draw_totals(y - 12)
            self.draw_footer(index + 1, len(pages))
            self.ctx.show_page()


def render(data: Input, path: str) -> None:
    # Rendered beside the target and renamed, so a failure can't truncate an
    # invoice that already exists at that path.
    temporary = f"{path}.partial"
    try:
        surface = cairo.PDFSurface(temporary, PAGE_WIDTH, PAGE_HEIGHT)
        surface.set_metadata(cairo.PDFMetadata.TITLE, f"Invoice {data.number}")
        ctx = cairo.Context(surface)
        options = cairo.FontOptions()
        options.set_hint_metrics(cairo.HINT_METRICS_OFF)
        ctx.set_font_options(options)
        _Renderer(ctx, data).render()
        surface.finish()
        os.replace(temporary, path)
    except (cairo.Error, OSError) as error:
        if os.path.exists(temporary):
            os.remove(temporary)
        raise DBError(f"Could not write to {path}: {error}") from error

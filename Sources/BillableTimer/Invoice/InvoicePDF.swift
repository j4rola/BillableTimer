import AppKit
import Foundation

/// Renders a client-ready invoice straight to a PDF with CoreGraphics — no HTML,
/// no print pipeline, no web view.
enum InvoicePDF {

    struct Input {
        var settings: AppSettings
        var client: Client
        var number: String
        var issuedAt: Date
        var period: DateRange
        var entries: [Entry]

        var spansClients: Bool { Set(entries.map(\.clientId)).count > 1 }
        var totalSeconds: Int { entries.reduce(0) { $0 + $1.seconds(asOf: $1.endedAt ?? Date()) } }
        var totalCents: Int { entries.reduce(0) { $0 + $1.amountCents(asOf: $1.endedAt ?? Date()) } }
    }

    // MARK: - Page geometry

    private static let pageWidth: CGFloat = 612    // US Letter
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 54
    private static let contentWidth = pageWidth - margin * 2
    private static let footerReserve: CGFloat = 34
    /// `boundingRect` under-reports multi-line height by a fraction of the final
    /// line's descender, which clips the last line. Draw into a slightly taller
    /// box — text is top-anchored, so the extra room only hangs off the bottom.
    private static let drawSlack: CGFloat = 5

    private struct Column {
        let x: CGFloat
        let width: CGFloat
        let alignment: NSTextAlignment
    }

    // 62 + 104 + 168 + 50 + 56 + 64 = 504 = contentWidth
    private static let colDate = Column(x: 54, width: 62, alignment: .left)
    private static let colProject = Column(x: 116, width: 104, alignment: .left)
    private static let colDescription = Column(x: 220, width: 168, alignment: .left)
    private static let colHours = Column(x: 388, width: 50, alignment: .right)
    private static let colRate = Column(x: 438, width: 56, alignment: .right)
    private static let colAmount = Column(x: 494, width: 64, alignment: .right)

    // MARK: - Fonts

    private static let titleFont = NSFont.systemFont(ofSize: 26, weight: .light)
    private static let headingFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private static let bodyFont = NSFont.systemFont(ofSize: 9.5, weight: .regular)
    private static let cellFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    private static let totalFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    private static let inkColor = NSColor.black
    private static let mutedColor = NSColor(white: 0.42, alpha: 1)
    private static let ruleColor = NSColor(white: 0.78, alpha: 1)

    // MARK: - Text helpers

    private static func attributed(
        _ text: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        tracking: CGFloat = 0
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 1
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func height(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(string.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
    }

    /// Draws text with its *top* edge at `topY` in the PDF's y-up coordinate space.
    @discardableResult
    private static func draw(
        _ text: String,
        font: NSFont,
        color: NSColor = inkColor,
        x: CGFloat,
        width: CGFloat,
        topY: CGFloat,
        alignment: NSTextAlignment = .left,
        tracking: CGFloat = 0
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let string = attributed(text, font: font, color: color, alignment: alignment, tracking: tracking)
        let textHeight = height(string, width: width)
        let boxHeight = textHeight + drawSlack
        string.draw(
            with: CGRect(x: x, y: topY - boxHeight, width: width, height: boxHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return textHeight
    }

    private static func drawRule(_ context: CGContext, y: CGFloat, color: NSColor = ruleColor, width: CGFloat = 0.5) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.move(to: CGPoint(x: margin, y: y))
        context.addLine(to: CGPoint(x: pageWidth - margin, y: y))
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Row layout

    private struct RenderRow {
        let date: String
        let project: String
        let description: String
        let hours: String
        let rate: String
        let amount: String
        let height: CGFloat
    }

    private static func buildRows(_ input: Input) -> [RenderRow] {
        let showingClient = input.spansClients
        return input.entries.map { entry in
            let end = entry.endedAt ?? Date()
            let seconds = entry.seconds(asOf: end)
            let description = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let date = Format.compactDate.string(from: entry.startedAt)
            let project = entry.invoiceLabel(showingClient: showingClient)
            let hours = Format.hours(seconds)
            let rate = Format.money(entry.rateCents)
            let amount = Format.money(entry.amountCents(asOf: end))

            // The row is as tall as its tallest wrapping cell.
            let cellHeights = [
                height(attributed(date, font: cellFont, color: inkColor, alignment: .left), width: colDate.width),
                height(attributed(project, font: cellFont, color: inkColor, alignment: .left), width: colProject.width),
                height(attributed(description.isEmpty ? "—" : description, font: cellFont, color: inkColor, alignment: .left), width: colDescription.width)
            ]
            return RenderRow(
                date: date,
                project: project,
                description: description.isEmpty ? "—" : description,
                hours: hours,
                rate: rate,
                amount: amount,
                height: (cellHeights.max() ?? 12) + 9   // 9pt of breathing room per row
            )
        }
    }

    // MARK: - Rendering

    static func render(_ input: Input, to url: URL) throws {
        let rows = buildRows(input)
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw DBError("Could not write to \(url.path).")
        }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DBError("Could not create a PDF context for \(url.path).")
        }

        // Paginate first so the footer can honestly say "Page 1 of 3".
        let firstPageTop = pageHeight - margin - headerHeight(input)
        let laterPageTop = pageHeight - margin
        var pages: [[RenderRow]] = []
        var current: [RenderRow] = []
        var cursor = firstPageTop - tableHeaderHeight
        for row in rows {
            if cursor - row.height < margin + footerReserve, !current.isEmpty {
                pages.append(current)
                current = []
                cursor = laterPageTop - tableHeaderHeight
            }
            current.append(row)
            cursor -= row.height
        }
        pages.append(current)

        // The totals block needs room on the final page; otherwise it gets its own.
        let totalsHeight: CGFloat = 96
        if cursor - totalsHeight < margin + footerReserve {
            pages.append([])
        }

        let pageCount = pages.count
        for (index, pageRows) in pages.enumerated() {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

            var y = pageHeight - margin
            if index == 0 {
                y = drawHeader(input, context: context, topY: y)
            }
            y = drawTableHeader(context: context, topY: y)

            for row in pageRows {
                drawRow(row, topY: y)
                y -= row.height
                drawRule(context, y: y + 2, color: NSColor(white: 0.90, alpha: 1), width: 0.4)
            }

            if index == pageCount - 1 {
                drawTotals(input, context: context, topY: y - 12)
            }
            drawFooter(input, page: index + 1, of: pageCount)

            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }

        context.closePDF()
    }

    // MARK: - Header

    private struct HeaderMetrics {
        let fromText: String
        let fromHeight: CGFloat
        let toText: String
        let toHeight: CGFloat
        /// Total vertical space the header consumes, so pagination and drawing agree.
        let total: CGFloat
    }

    private static let addressWidth: CGFloat = 240

    /// Measured up front so pagination knows exactly how much room page 1 loses.
    private static func headerMetrics(_ input: Input) -> HeaderMetrics {
        let fromText = [input.settings.businessName, input.settings.businessAddress, input.settings.businessEmail]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let toText = [input.client.name, input.client.address]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        // Floors keep the layout from collapsing when a block is short or empty.
        let fromHeight = max(
            height(attributed(fromText.isEmpty ? "—" : fromText, font: bodyFont, color: inkColor, alignment: .left), width: addressWidth),
            31
        )
        let toHeight = max(
            height(attributed(toText.isEmpty ? "—" : toText, font: bodyFont, color: inkColor, alignment: .left), width: addressWidth),
            17
        )

        // 34 title + 13 label + from + 26 gap + 13 label + to + 30 gap, plus the
        // slack each drawn block hangs below its measured height.
        return HeaderMetrics(
            fromText: fromText,
            fromHeight: fromHeight,
            toText: toText,
            toHeight: toHeight,
            total: 116 + fromHeight + toHeight + drawSlack * 2
        )
    }

    private static func headerHeight(_ input: Input) -> CGFloat { headerMetrics(input).total }

    private static func drawHeader(_ input: Input, context: CGContext, topY: CGFloat) -> CGFloat {
        let metrics = headerMetrics(input)
        var y = topY

        // Title on the left, invoice metadata on the right.
        draw("INVOICE", font: titleFont, color: inkColor, x: margin, width: 260, topY: y, tracking: 1.5)

        let metaLines: [(String, String)] = [
            ("INVOICE NO.", input.number),
            ("DATE", Format.shortDate.string(from: input.issuedAt)),
            ("PERIOD", "\(Format.compactDate.string(from: input.period.start)) – \(Format.compactDate.string(from: input.period.lastDay))")
        ]
        var metaY = y - 2
        for (label, value) in metaLines {
            draw(label, font: labelFont, color: mutedColor, x: pageWidth - margin - 200, width: 90, topY: metaY, alignment: .right, tracking: 0.6)
            draw(value, font: bodyFont, color: inkColor, x: pageWidth - margin - 104, width: 104, topY: metaY, alignment: .right)
            metaY -= 15
        }

        y -= 34

        draw("FROM", font: labelFont, color: mutedColor, x: margin, width: addressWidth, topY: y, tracking: 0.6)
        draw(
            metrics.fromText.isEmpty ? "—" : metrics.fromText,
            font: bodyFont, color: inkColor, x: margin, width: addressWidth, topY: y - 13
        )
        y -= 13 + metrics.fromHeight + drawSlack + 26

        draw("BILL TO", font: labelFont, color: mutedColor, x: margin, width: addressWidth, topY: y, tracking: 0.6)
        draw(
            metrics.toText.isEmpty ? "—" : metrics.toText,
            font: bodyFont, color: inkColor, x: margin, width: addressWidth, topY: y - 13
        )
        y -= 13 + metrics.toHeight + drawSlack + 30

        return y
    }

    // MARK: - Table

    private static let tableHeaderHeight: CGFloat = 22

    private static func drawTableHeader(context: CGContext, topY: CGFloat) -> CGFloat {
        drawRule(context, y: topY, color: inkColor, width: 0.8)
        let y = topY - 6
        draw("DATE", font: labelFont, color: mutedColor, x: colDate.x, width: colDate.width, topY: y, tracking: 0.6)
        draw("PROJECT", font: labelFont, color: mutedColor, x: colProject.x, width: colProject.width, topY: y, tracking: 0.6)
        draw("DESCRIPTION", font: labelFont, color: mutedColor, x: colDescription.x, width: colDescription.width, topY: y, tracking: 0.6)
        draw("HOURS", font: labelFont, color: mutedColor, x: colHours.x, width: colHours.width, topY: y, alignment: .right, tracking: 0.6)
        draw("RATE", font: labelFont, color: mutedColor, x: colRate.x, width: colRate.width, topY: y, alignment: .right, tracking: 0.6)
        draw("AMOUNT", font: labelFont, color: mutedColor, x: colAmount.x, width: colAmount.width, topY: y, alignment: .right, tracking: 0.6)
        return topY - tableHeaderHeight
    }

    private static func drawRow(_ row: RenderRow, topY: CGFloat) {
        let y = topY - 3
        draw(row.date, font: cellFont, color: mutedColor, x: colDate.x, width: colDate.width, topY: y)
        draw(row.project, font: cellFont, x: colProject.x, width: colProject.width, topY: y)
        draw(row.description, font: cellFont, x: colDescription.x, width: colDescription.width, topY: y)
        draw(row.hours, font: cellFont, x: colHours.x, width: colHours.width, topY: y, alignment: .right)
        draw(row.rate, font: cellFont, color: mutedColor, x: colRate.x, width: colRate.width, topY: y, alignment: .right)
        draw(row.amount, font: cellFont, x: colAmount.x, width: colAmount.width, topY: y, alignment: .right)
    }

    private static func drawTotals(_ input: Input, context: CGContext, topY: CGFloat) {
        var y = topY
        drawRule(context, y: y, color: inkColor, width: 0.8)
        y -= 12

        draw("Total hours", font: bodyFont, color: mutedColor, x: colDescription.x, width: 218, topY: y, alignment: .right)
        draw(Format.hours(input.totalSeconds), font: bodyFont, x: colRate.x, width: colRate.width + colAmount.width, topY: y, alignment: .right)
        y -= 20

        draw("AMOUNT DUE", font: headingFont, x: colDescription.x, width: 218, topY: y, alignment: .right)
        draw(Format.money(input.totalCents), font: totalFont, x: colRate.x, width: colRate.width + colAmount.width, topY: y + 3, alignment: .right)
        y -= 30

        if !input.settings.invoiceTerms.isEmpty {
            draw(input.settings.invoiceTerms, font: bodyFont, color: mutedColor, x: margin, width: 300, topY: y)
        }
    }

    private static func drawFooter(_ input: Input, page: Int, of pageCount: Int) {
        let left = input.settings.businessName.isEmpty ? input.client.name : input.settings.businessName
        draw(left, font: cellFont, color: mutedColor, x: margin, width: 300, topY: margin - 6)
        if pageCount > 1 {
            draw(
                "Page \(page) of \(pageCount)",
                font: cellFont, color: mutedColor,
                x: pageWidth - margin - 140, width: 140, topY: margin - 6, alignment: .right
            )
        }
    }
}

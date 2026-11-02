import SwiftUI
import AppKit

struct InvoicesView: View {
    @EnvironmentObject var model: AppModel

    /// Ticked clients, in the order they were ticked. The first is the one billed.
    @State private var selectedIds: [Int64] = []
    @State private var showingClients = false
    @State private var periodStart = Date()
    @State private var periodEnd = Date()
    @State private var billable: [Entry] = []
    @State private var initialized = false

    /// The client billed: whichever was ticked first.
    private var selectedClient: Client? {
        model.clients.first { $0.id == selectedIds.first }
    }

    private var selectedNames: String {
        selectedIds
            .compactMap { id in model.clients.first { $0.id == id }?.name }
            .joined(separator: " + ")
    }

    private var range: DateRange {
        let calendar = Periods.calendar(firstWeekday: model.settings.firstWeekday)
        let start = calendar.startOfDay(for: periodStart)
        let endDay = calendar.startOfDay(for: periodEnd)
        let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
        return DateRange(start: start, end: max(end, start))
    }

    private var totalSeconds: Int {
        billable.reduce(0) { $0 + $1.seconds(asOf: $1.endedAt ?? Date()) }
    }

    private var totalCents: Int {
        billable.reduce(0) { $0 + $1.amountCents(asOf: $1.endedAt ?? Date()) }
    }

    private var invoiceNumber: String {
        "\(model.settings.invoicePrefix)\(String(format: "%04d", model.settings.nextInvoiceNumber))"
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Invoices", subtitle: "Bills stopped, not-yet-invoiced time for one client, or several combined.")

            if model.clients.isEmpty {
                EmptyHint(
                    icon: "doc.text",
                    title: "No clients yet",
                    message: "Add a client with a rate before generating an invoice."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        controls
                        preview
                        history
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear(perform: initializeOnce)
    }

    private func initializeOnce() {
        guard !initialized else { return }
        initialized = true
        selectedIds = model.clients.first.map { [$0.id] } ?? []
        // Default to the two-week period that just ended.
        let current = Periods.twoWeeks(
            containing: Date(),
            anchor: model.settings.periodAnchor,
            firstWeekday: model.settings.firstWeekday
        )
        periodStart = current.start
        periodEnd = current.lastDay
        refresh()
    }

    private func refresh() {
        do {
            billable = try selectedIds
                .flatMap { try model.store.billableEntries(clientId: $0, in: range) }
                .sorted { $0.startedAt < $1.startedAt }
        } catch {
            model.errorMessage = error.localizedDescription
            billable = []
        }
    }

    // MARK: - Controls

    private func isSelected(_ id: Int64) -> Binding<Bool> {
        Binding(
            get: { selectedIds.contains(id) },
            set: { ticked in
                selectedIds.removeAll { $0 == id }
                if ticked { selectedIds.append(id) }
                refresh()
            }
        )
    }

    /// A popover rather than a `Menu`, which would close after every tick.
    private var clientChooser: some View {
        HStack(spacing: 8) {
            Text("Bill to")
            Button {
                showingClients.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(selectedNames.isEmpty ? "Choose Clients…" : selectedNames)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
            }
            .popover(isPresented: $showingClients, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.clients) { client in
                        Toggle(client.name, isOn: isSelected(client.id))
                            .toggleStyle(.checkbox)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 260)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                clientChooser

                DatePicker("From", selection: Binding(
                    get: { periodStart },
                    set: { periodStart = $0; refresh() }
                ), displayedComponents: .date)

                DatePicker("To", selection: Binding(
                    get: { periodEnd },
                    set: { periodEnd = $0; refresh() }
                ), displayedComponents: .date)

                Button("Last 2 Weeks") {
                    let previous = Periods.twoWeeks(
                        containing: Date().addingTimeInterval(-14 * 86_400),
                        anchor: model.settings.periodAnchor,
                        firstWeekday: model.settings.firstWeekday
                    )
                    periodStart = previous.start
                    periodEnd = previous.lastDay
                    refresh()
                }
            }

            HStack(spacing: 12) {
                StatTile(label: "Invoice no.", value: invoiceNumber)
                StatTile(label: "Entries", value: "\(billable.count)")
                StatTile(label: "Hours", value: Format.hours(totalSeconds))
                StatTile(label: "Amount due", value: Format.money(totalCents), accent: .green)
            }

            HStack {
                Button {
                    generate()
                } label: {
                    Label("Generate PDF…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(billable.isEmpty || selectedClient == nil)

                if !model.running.isEmpty {
                    Label("\(model.running.count) timer\(model.running.count == 1 ? "" : "s") still running — that time won't be included until stopped.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lines on this invoice")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if billable.isEmpty {
                Text("No uninvoiced, stopped time for this client in this date range.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(billable) { entry in
                        HStack(spacing: 12) {
                            Text(Format.compactDate.string(from: entry.startedAt))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .leading)
                            Text(entry.invoiceLabel(showingClient: selectedIds.count > 1))
                                .font(.caption)
                                .frame(width: 150, alignment: .leading)
                                .lineLimit(1)
                            Text(entry.note.isEmpty ? "—" : entry.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Format.hours(entry.seconds(asOf: entry.endedAt ?? Date())))
                                .font(.caption.monospacedDigit())
                                .frame(width: 48, alignment: .trailing)
                            Text(Format.money(entry.rateCents))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 64, alignment: .trailing)
                            Text(Format.money(entry.amountCents(asOf: entry.endedAt ?? Date())))
                                .font(.caption.monospacedDigit())
                                .frame(width: 74, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private var history: some View {
        if !model.invoices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Issued")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(model.invoices) { invoice in
                        HStack(spacing: 12) {
                            Text(invoice.number)
                                .font(.caption.monospacedDigit().weight(.medium))
                                .frame(width: 90, alignment: .leading)
                            Text(invoice.clientLabel)
                                .font(.caption)
                                .frame(width: 160, alignment: .leading)
                                .lineLimit(1)
                            Text("\(Format.compactDate.string(from: invoice.periodStart)) – \(Format.compactDate.string(from: invoice.periodEnd))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(Format.hours(invoice.seconds) + " h")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)
                            Text(Format.money(invoice.totalCents))
                                .font(.caption.monospacedDigit())
                                .frame(width: 80, alignment: .trailing)

                            Menu {
                                Button("Open PDF") { open(invoice) }
                                    .disabled(invoice.filePath.isEmpty)
                                Button("Show in Finder") { reveal(invoice) }
                                    .disabled(invoice.filePath.isEmpty)
                                Divider()
                                Button("Delete & Unbill Entries", role: .destructive) { delete(invoice) }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: 28)
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func generate() {
        guard let client = selectedClient, !billable.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Save Invoice"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue =
            "\(invoiceNumber) \(client.name) \(Format.fileStamp.string(from: range.lastDay)).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let input = InvoicePDF.Input(
            settings: model.settings,
            client: client,
            number: invoiceNumber,
            issuedAt: Date(),
            period: range,
            entries: billable
        )

        do {
            try InvoicePDF.render(input, to: url)
            try model.store.recordInvoice(
                clientId: client.id,
                number: invoiceNumber,
                periodStart: range.start,
                periodEnd: range.lastDay,
                entries: billable,
                totalCents: totalCents,
                seconds: totalSeconds,
                filePath: url.path
            )
            model.settings.nextInvoiceNumber += 1
            model.saveSettings()
            model.reloadAll()
            refresh()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func open(_ invoice: Invoice) {
        NSWorkspace.shared.open(URL(fileURLWithPath: invoice.filePath))
    }

    private func reveal(_ invoice: Invoice) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: invoice.filePath)])
    }

    private func delete(_ invoice: Invoice) {
        do {
            try model.store.deleteInvoice(id: invoice.id)
            model.reloadAll()
            refresh()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

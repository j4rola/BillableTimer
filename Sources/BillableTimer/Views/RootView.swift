import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case timers = "Timers"
    case entries = "Entries"
    case reports = "Reports"
    case clients = "Clients & Projects"
    case invoices = "Invoices"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .timers: return "stopwatch"
        case .entries: return "list.bullet.rectangle"
        case .reports: return "chart.bar"
        case .clients: return "person.2"
        case .invoices: return "doc.text"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var bridge: WindowBridge
    @Environment(\.openWindow) private var openWindow
    @State private var section: AppSection = .timers

    // `.safeAreaInset` and `.overlay` are attached unconditionally, so SwiftUI
    // keeps re-laying out their content even when it resolves to `EmptyView` —
    // measured at ~1.7% CPU, permanently, on an idle foreground window. Composing
    // the same UI with a plain VStack and ZStack, where the conditional is a real
    // branch rather than an empty modifier, costs nothing when there is nothing
    // to show.
    var body: some View {
        ZStack(alignment: .top) {
            splitView
            if let message = model.errorMessage {
                errorBanner(message)
            }
        }
        // `openWindow` is only readable inside a Scene, so hand a copy to the
        // status item, which may need it long after this window has closed.
        .task { bridge.openMain = { openWindow(id: "main") } }
    }

    private var splitView: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(AppSection.allCases, selection: $section) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
                if !model.running.isEmpty {
                    runningFooter
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch section {
                case .timers: TimersView()
                case .entries: EntriesView()
                case .reports: ReportsView()
                case .clients: ClientsView()
                case .invoices: InvoicesView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A persistent reminder of what's on the clock, visible from any section.
    private var runningFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                Text("\(model.running.count) running")
                    .font(.caption)
                Spacer()
                LiveDuration(entries: model.running)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.35)))
        .shadow(radius: 8, y: 2)
        .padding()
        .frame(maxWidth: 560)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Live readouts

enum DurationStyle {
    /// 1:04:22
    case clock
    /// 1h 04m
    case compact
}

/// A single self-updating duration. Because only this leaf observes `Clock`,
/// ticking never redraws the surrounding list, grid, or text fields.
struct LiveDuration: View {
    @EnvironmentObject private var clock: Clock
    let entries: [Entry]
    var style: DurationStyle = .clock

    init(entry: Entry, style: DurationStyle = .clock) {
        self.entries = [entry]
        self.style = style
    }

    init(entries: [Entry], style: DurationStyle = .clock) {
        self.entries = entries
        self.style = style
    }

    var body: some View {
        let seconds = entries.reduce(0) { $0 + $1.seconds(asOf: clock.now) }
        Text(style == .clock ? Format.clock(seconds) : Format.duration(seconds))
            .monospacedDigit()
    }
}

// MARK: - Shared building blocks

/// Section header used across the detail panes.
struct PaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// ‹ Today › navigation shared by Entries and Reports.
struct PeriodBar: View {
    @EnvironmentObject var model: AppModel
    var showKindPicker: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            if showKindPicker {
                Picker("", selection: Binding(
                    get: { model.periodKind },
                    set: { model.periodKind = $0; model.reloadEntries() }
                )) {
                    ForEach(PeriodKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
            }

            Spacer()

            Button { model.shiftPeriod(by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)

            Text(model.rangeLabel)
                .font(.callout.weight(.medium))
                .frame(minWidth: 180)
                .multilineTextAlignment(.center)

            Button { model.shiftPeriod(by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)

            Button("Today") { model.jumpToToday() }
                .disabled(model.isCurrentPeriod)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

/// A large number with a caption, used for the totals row.
struct StatTile: View {
    let label: String
    let value: String
    var accent: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EmptyHint: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

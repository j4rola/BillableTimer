import SwiftUI

struct ReportsView: View {
    @EnvironmentObject var model: AppModel
    @State private var expandedClients: Set<Int64> = []

    private var dayTotals: [DayTotal] { model.dayTotals }

    /// Averaged over days that actually had time on them, not calendar days.
    private var averageWorkedDaySeconds: Int {
        let worked = dayTotals.filter { $0.seconds > 0 }
        guard !worked.isEmpty else { return 0 }
        return worked.reduce(0) { $0 + $1.seconds } / worked.count
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Reports", subtitle: "Totals by day, week, and two-week period.")
            PeriodBar()
                // Reports opens on today's figures rather than inheriting wherever
                // the period controls were left in Entries.
                .onAppear { model.showToday() }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    statsRow

                    if dayTotals.count > 1 {
                        chartSection
                    }

                    if model.visibleEntries.isEmpty {
                        EmptyHint(
                            icon: "chart.bar",
                            title: "No time in this period",
                            message: "Once you log some time it will break down by client and project here."
                        )
                        .frame(height: 200)
                    } else {
                        clientSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 26)
            }
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatTile(label: "Total hours", value: Format.hours(model.totalSeconds))
            StatTile(label: "Time", value: Format.duration(model.totalSeconds))
            StatTile(label: "Avg / worked day", value: Format.duration(averageWorkedDaySeconds))
            StatTile(label: "Billable value", value: Format.money(model.totalAmountCents), accent: .green)
        }
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            DailyBarChart(days: dayTotals)
                .frame(height: 150)
        }
    }

    // MARK: - Breakdown

    private var clientSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By client")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(model.clientBreakdown, id: \.row.id) { item in
                    ClientBreakdownRow(
                        row: item.row,
                        amountCents: item.amountCents,
                        totalSeconds: model.totalSeconds,
                        isExpanded: expandedClients.contains(item.row.clientId),
                        projects: model.projectBreakdown.filter { $0.clientId == item.row.clientId }
                    ) {
                        if expandedClients.contains(item.row.clientId) {
                            expandedClients.remove(item.row.clientId)
                        } else {
                            expandedClients.insert(item.row.clientId)
                        }
                    }
                    Divider()
                }
            }
        }
    }
}

// MARK: - Bar chart

/// Hand-drawn so the app pulls in no charting framework — it's a bar per day.
private struct DailyBarChart: View {
    let days: [DayTotal]

    private var peak: Int { max(days.map(\.seconds).max() ?? 0, 1) }

    var body: some View {
        GeometryReader { geometry in
            let count = max(days.count, 1)
            let spacing: CGFloat = days.count > 7 ? 4 : 8
            let barWidth = max(6, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let labelHeight: CGFloat = 30
            let plotHeight = max(1, geometry.size.height - labelHeight)

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(days) { day in
                    VStack(spacing: 5) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.quaternary.opacity(0.4))
                                .frame(height: plotHeight)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(day.seconds > 0 ? Color.accentColor : Color.clear)
                                .frame(height: plotHeight * CGFloat(day.seconds) / CGFloat(peak))
                        }
                        .frame(height: plotHeight)
                        .overlay(alignment: .top) {
                            if day.seconds > 0 {
                                Text(Format.hours(day.seconds))
                                    .font(.system(size: 8).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .offset(y: max(0, plotHeight - plotHeight * CGFloat(day.seconds) / CGFloat(peak) - 11))
                            }
                        }

                        Text(Format.dayLabel.string(from: day.day))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(height: labelHeight - 5)
                    }
                    .frame(width: barWidth)
                }
            }
        }
    }
}

// MARK: - Rows

private struct ClientBreakdownRow: View {
    let row: BreakdownRow
    let amountCents: Int
    let totalSeconds: Int
    let isExpanded: Bool
    let projects: [BreakdownRow]
    let toggle: () -> Void

    private var share: Double {
        totalSeconds > 0 ? Double(row.seconds) / Double(totalSeconds) : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)

                    Text(row.clientName)
                        .font(.subheadline.weight(.medium))

                    Spacer(minLength: 12)

                    // Share-of-period bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary.opacity(0.4))
                            Capsule()
                                .fill(Color.accentColor.opacity(0.75))
                                .frame(width: geometry.size.width * share)
                        }
                        .frame(height: 5)
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(width: 120, height: 16)

                    Text("\(Int((share * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)

                    Text(Format.duration(row.seconds))
                        .font(.callout.monospacedDigit())
                        .frame(width: 74, alignment: .trailing)

                    Text(Format.hours(row.seconds))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)

                    Text(Format.money(amountCents))
                        .font(.callout.monospacedDigit())
                        .frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(projects) { project in
                    HStack(spacing: 10) {
                        Text(project.projectName ?? "—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                        Spacer(minLength: 12)
                        Text(Format.money(project.rateCents) + "/h")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 158, alignment: .trailing)
                        Text(Format.duration(project.seconds))
                            .font(.caption.monospacedDigit())
                            .frame(width: 74, alignment: .trailing)
                        Text(Format.hours(project.seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                        Text(Format.money(project.amountCents))
                            .font(.caption.monospacedDigit())
                            .frame(width: 84, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                }
                .padding(.bottom, 6)
            }
        }
    }
}

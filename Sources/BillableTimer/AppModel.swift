import Foundation
import AppKit
import Combine

/// The second-hand, deliberately kept off `AppModel`.
///
/// If the ticking value lived on the model, every one-second tick would
/// invalidate every view observing the model — the whole entry table, the project
/// grid, and the description fields on running timers. Only the small leaf views
/// that actually display a live number observe this object.
@MainActor
final class Clock: ObservableObject {
    @Published private(set) var now = Date()

    func advance(to date: Date) { now = date }
}

@MainActor
final class AppModel: ObservableObject {
    let store: Store

    /// Fine-grained clock for live readouts (1 Hz).
    let clock = Clock()

    @Published private(set) var clients: [Client] = []
    @Published private(set) var projects: [Project] = []
    @Published private(set) var running: [Entry] = []
    @Published private(set) var visibleEntries: [Entry] = []
    /// Today's entries, tracked separately from the browsed range so the menu bar
    /// and project tiles stay correct while you're looking at a past period.
    @Published private(set) var todayEntries: [Entry] = []
    @Published private(set) var invoices: [Invoice] = []
    @Published var settings: AppSettings

    /// Coarse clock driving totals and tables. Running time only needs to be
    /// re-aggregated occasionally, so these views redraw 4×/minute, not 60×.
    @Published private(set) var coarseTick: Date = Date()

    /// What aggregate views and tables measure against.
    var tick: Date { coarseTick }

    @Published var periodKind: PeriodKind = .day
    @Published var referenceDate: Date = Date()
    @Published var errorMessage: String?

    /// Set once the user browses away from the current period with the arrows,
    /// cleared by Today. It is what tells a midnight rollover whether to carry the
    /// view forward or leave the user where they deliberately went.
    private var isBrowsingPast = false

    private var ticker: Timer?
    private var tickCount = 0
    private var wakeObserver: NSObjectProtocol?
    private var dayChangeObserver: NSObjectProtocol?

    /// Ticks between coarse refreshes.
    private static let coarseInterval = 15

    init() throws {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BillableTimer", isDirectory: true)
        store = try Store(directory: support)
        settings = try store.loadSettings()
        reloadAll()
        observeWake()
        observeDayChange()
    }

    deinit {
        ticker?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let dayChangeObserver {
            NotificationCenter.default.removeObserver(dayChangeObserver)
        }
    }

    // MARK: - Current range

    var range: DateRange {
        Periods.range(periodKind, containing: referenceDate, settings: settings)
    }

    var rangeLabel: String { Format.rangeLabel(range, kind: periodKind) }

    var isCurrentPeriod: Bool { range.contains(Date()) }

    func shiftPeriod(by steps: Int) {
        let calendar = Periods.calendar(firstWeekday: settings.firstWeekday)
        let days = steps * periodKind.strideDays
        if let shifted = calendar.date(byAdding: .day, value: days, to: referenceDate) {
            referenceDate = shifted
            isBrowsingPast = !Periods.range(periodKind, containing: shifted, settings: settings).contains(Date())
            reloadEntries()
        }
    }

    func jumpToToday() {
        referenceDate = Date()
        isBrowsingPast = false
        reloadEntries()
    }

    /// Snaps back to today's figures. Reports opens on this so it always answers
    /// "how am I doing today" rather than wherever the period controls were left.
    func showToday() {
        periodKind = .day
        referenceDate = Date()
        isBrowsingPast = false
        reloadEntries()
    }

    /// Carries the view onto the new day when the clock rolls past midnight, which
    /// an app that stays open overnight will otherwise miss entirely — `referenceDate`
    /// is captured once and would keep pointing at the day the app launched.
    /// Someone who deliberately navigated to a past period is left where they are.
    private func rollOverIfNeeded() {
        if !isBrowsingPast, !isCurrentPeriod {
            referenceDate = Date()
        }
        reloadEntries()
    }

    private func observeDayChange() {
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rollOverIfNeeded() }
        }
    }

    // MARK: - Loading

    func reloadAll() {
        perform {
            clients = try store.clients()
            projects = try store.projects()
            invoices = try store.invoices()
        }
        reloadRunning()
        reloadEntries()
    }

    func reloadEntries() {
        perform {
            visibleEntries = try store.entries(in: range)
            let today = Periods.day(containing: Date(), firstWeekday: settings.firstWeekday)
            // Reuse the visible rows when they already cover today.
            todayEntries = range.contains(today.start) && range.end >= today.end
                ? visibleEntries.filter { today.contains($0.startedAt) }
                : try store.entries(in: today)
        }
        refreshCoarseClock()
    }

    func todayEntries(forProject projectId: Int64) -> [Entry] {
        todayEntries.filter { $0.projectId == projectId }
    }

    func reloadRunning() {
        perform { running = try store.runningEntries() }
        syncTicker()
    }

    /// Runs a throwing block and surfaces any failure in the UI banner instead of crashing.
    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Ticking

    /// The ticker exists only while something is running, so an idle app does no
    /// periodic work at all. A 1s interval with generous tolerance lets macOS
    /// coalesce the wakeups. One timer drives both clocks.
    private func syncTicker() {
        if running.isEmpty {
            ticker?.invalidate()
            ticker = nil
            tickCount = 0
            return
        }
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func onTick() {
        let now = Date()
        clock.advance(to: now)
        tickCount += 1
        if tickCount >= Self.coarseInterval {
            tickCount = 0
            coarseTick = now
        }
    }

    /// Brings the coarse clock forward immediately — used when data changes, so
    /// tables don't sit stale for up to 15 seconds after an edit.
    private func refreshCoarseClock() {
        tickCount = 0
        coarseTick = Date()
    }

    /// Elapsed time is always derived from stored wall-clock timestamps, so sleep
    /// is handled correctly on its own; waking just needs a redraw.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clock.advance(to: Date())
                self?.reloadRunning()
                // Sleeping through midnight doesn't reliably deliver a day-change
                // notification, so re-check the date on the way back up.
                self?.rollOverIfNeeded()
            }
        }
    }

    // MARK: - Timer actions

    func startTimer(projectId: Int64, note: String = "") {
        perform { try store.startTimer(projectId: projectId, note: note) }
        reloadRunning()
        reloadEntries()
    }

    func stopTimer(_ entry: Entry) {
        perform { try store.stopTimer(entryId: entry.id) }
        reloadRunning()
        reloadEntries()
    }

    func stopAll() {
        perform { try store.stopAllTimers() }
        reloadRunning()
        reloadEntries()
    }

    func cancelTimer(_ entry: Entry) {
        perform { try store.cancelTimer(entryId: entry.id) }
        reloadRunning()
        reloadEntries()
    }

    func isRunning(projectId: Int64) -> Bool {
        running.contains { $0.projectId == projectId }
    }

    /// Total elapsed across every running timer as of a given instant.
    func runningSeconds(asOf now: Date) -> Int {
        running.reduce(0) { $0 + $1.seconds(asOf: now) }
    }

    // MARK: - Entry actions

    func addManualEntry(projectId: Int64, start: Date, end: Date, note: String) {
        perform { try store.addManualEntry(projectId: projectId, start: start, end: end, note: note) }
        reloadEntries()
    }

    func updateEntry(id: Int64, projectId: Int64, start: Date, end: Date?, note: String) {
        perform { try store.updateEntry(id: id, projectId: projectId, start: start, end: end, note: note) }
        reloadEntries()
        reloadRunning()
    }

    func deleteEntry(_ entry: Entry) {
        perform { try store.deleteEntry(id: entry.id) }
        reloadEntries()
        reloadRunning()
    }

    // MARK: - Client & project actions

    func createClient(name: String, rateCents: Int, address: String, notes: String) {
        perform { try store.createClient(name: name, rateCents: rateCents, address: address, notes: notes) }
        reloadAll()
    }

    func updateClient(_ client: Client) {
        perform { try store.updateClient(client) }
        reloadAll()
    }

    func deleteClient(_ client: Client) {
        perform { try store.deleteClient(id: client.id) }
        reloadAll()
    }

    func createProject(clientId: Int64, name: String, rateCents: Int?) {
        perform { try store.createProject(clientId: clientId, name: name, rateCents: rateCents) }
        reloadAll()
    }

    func updateProject(_ project: Project) {
        perform { try store.updateProject(project) }
        reloadAll()
    }

    func deleteProject(_ project: Project) {
        perform { try store.deleteProject(id: project.id) }
        reloadAll()
    }

    func projects(for clientId: Int64) -> [Project] {
        projects.filter { $0.clientId == clientId }
    }

    // MARK: - Settings

    func saveSettings() {
        perform { try store.saveSettings(settings) }
        reloadEntries()
    }

    // MARK: - Reporting

    /// Per-project totals for the visible range.
    var projectBreakdown: [BreakdownRow] {
        var accumulator: [Int64: BreakdownRow] = [:]
        for entry in visibleEntries {
            let seconds = entry.seconds(asOf: tick)
            if var existing = accumulator[entry.projectId] {
                existing.seconds += seconds
                accumulator[entry.projectId] = existing
            } else {
                accumulator[entry.projectId] = BreakdownRow(
                    id: "project-\(entry.projectId)",
                    clientId: entry.clientId,
                    clientName: entry.clientName,
                    projectId: entry.projectId,
                    projectName: entry.projectName,
                    seconds: seconds,
                    rateCents: entry.rateCents
                )
            }
        }
        return accumulator.values.sorted {
            ($0.clientName, $0.projectName ?? "") < ($1.clientName, $1.projectName ?? "")
        }
    }

    /// Per-client totals. Amounts are summed from the project rows rather than
    /// recomputed from one rate, since projects can carry their own rates.
    var clientBreakdown: [(row: BreakdownRow, amountCents: Int)] {
        var seconds: [Int64: Int] = [:]
        var amounts: [Int64: Int] = [:]
        var names: [Int64: String] = [:]
        for row in projectBreakdown {
            seconds[row.clientId, default: 0] += row.seconds
            amounts[row.clientId, default: 0] += row.amountCents
            names[row.clientId] = row.clientName
        }
        return seconds.keys.map { clientId in
            let row = BreakdownRow(
                id: "client-\(clientId)",
                clientId: clientId,
                clientName: names[clientId] ?? "—",
                projectId: nil,
                projectName: nil,
                seconds: seconds[clientId] ?? 0,
                rateCents: 0
            )
            return (row, amounts[clientId] ?? 0)
        }
        .sorted { $0.row.clientName < $1.row.clientName }
    }

    var totalSeconds: Int {
        visibleEntries.reduce(0) { $0 + $1.seconds(asOf: tick) }
    }

    var totalAmountCents: Int {
        projectBreakdown.reduce(0) { $0 + $1.amountCents }
    }

    /// Day-by-day totals across the visible range, including empty days so the
    /// chart keeps a stable shape.
    var dayTotals: [DayTotal] {
        let calendar = Periods.calendar(firstWeekday: settings.firstWeekday)
        var buckets: [Date: Int] = [:]
        for entry in visibleEntries {
            let day = calendar.startOfDay(for: entry.startedAt)
            buckets[day, default: 0] += entry.seconds(asOf: tick)
        }
        return Periods.days(in: range, firstWeekday: settings.firstWeekday).map {
            DayTotal(day: $0, seconds: buckets[$0] ?? 0)
        }
    }
}

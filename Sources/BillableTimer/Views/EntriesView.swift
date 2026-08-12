import SwiftUI

struct EntriesView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Entry?
    @State private var addingNew = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Entries", subtitle: "Entries count toward the day they started on.") {
                Button {
                    addingNew = true
                } label: {
                    Label("Add Entry", systemImage: "plus")
                }
                .disabled(model.projects.isEmpty)
            }

            PeriodBar()

            HStack(spacing: 12) {
                StatTile(label: "Entries", value: "\(model.visibleEntries.count)")
                StatTile(label: "Time", value: Format.duration(model.totalSeconds))
                StatTile(label: "Hours", value: Format.hours(model.totalSeconds))
                StatTile(label: "Value", value: Format.money(model.totalAmountCents), accent: .green)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if model.visibleEntries.isEmpty {
                EmptyHint(
                    icon: "list.bullet.rectangle",
                    title: "Nothing logged in this period",
                    message: "Start a timer, or use Add Entry to record time you tracked elsewhere."
                )
            } else {
                entryTable
            }
        }
        .sheet(item: $editing) { entry in
            EntryEditor(entry: entry).environmentObject(model)
        }
        .sheet(isPresented: $addingNew) {
            EntryEditor(entry: nil).environmentObject(model)
        }
    }

    private var entryTable: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visibleEntries) { entry in
                    EntryRow(entry: entry) {
                        editing = entry
                    } onDelete: {
                        model.deleteEntry(entry)
                    }
                    .environmentObject(model)
                    Divider()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
}

private struct EntryRow: View {
    @EnvironmentObject var model: AppModel
    let entry: Entry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.dayLabel.string(from: entry.startedAt))
                    .font(.caption.weight(.medium))
                Text(timeSpan)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.projectName).font(.subheadline.weight(.medium))
                    if entry.isRunning {
                        Text("RUNNING")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.red.opacity(0.18), in: Capsule())
                            .foregroundStyle(.red)
                    }
                    if entry.invoiceId != nil {
                        Text("INVOICED")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.16), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(entry.note.isEmpty ? entry.clientName : "\(entry.clientName) — \(entry.note)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(Format.duration(entry.seconds(asOf: model.tick)))
                .font(.callout.monospacedDigit())
                .frame(width: 70, alignment: .trailing)

            Text(Format.hours(entry.seconds(asOf: model.tick)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)

            Text(Format.money(entry.amountCents(asOf: model.tick)))
                .font(.callout.monospacedDigit())
                .frame(width: 80, alignment: .trailing)

            Menu {
                Button("Edit…", action: onEdit)
                    .disabled(entry.invoiceId != nil)
                if entry.isRunning {
                    Button("Stop") { model.stopTimer(entry) }
                }
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
                    .disabled(entry.invoiceId != nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
        }
        .padding(.vertical, 9)
    }

    private var timeSpan: String {
        let start = Format.timeOfDay.string(from: entry.startedAt)
        guard let end = entry.endedAt else { return "\(start) – now" }
        return "\(start) – \(Format.timeOfDay.string(from: end))"
    }
}

// MARK: - Editor

/// How time is typed in. Both routes produce the same thing: a start instant and
/// an end instant.
enum EntryInputMode: String, CaseIterable, Identifiable {
    case duration = "Duration"
    case startEnd = "Start & End"

    var id: String { rawValue }
}

/// Creates a manual entry when `entry` is nil, otherwise edits an existing one.
struct EntryEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let entry: Entry?

    @State private var projectId: Int64 = 0
    @State private var start = Date()
    @State private var end = Date()
    @State private var note = ""
    @State private var loaded = false

    @State private var mode: EntryInputMode = .duration
    @State private var hoursText = ""
    @State private var minutesText = ""

    /// How long the entry lasted, however it was entered. nil means the input
    /// can't be read (bad text, or an end before the start).
    private var durationSeconds: Int? {
        switch mode {
        case .startEnd:
            let seconds = Int(end.timeIntervalSince(start))
            return seconds >= 0 ? seconds : nil
        case .duration:
            return Format.parseDuration(hours: hoursText, minutes: minutesText)
        }
    }

    /// In duration mode the end time is derived, never typed.
    private var resolvedEnd: Date? {
        guard let durationSeconds else { return nil }
        return mode == .startEnd ? end : start.addingTimeInterval(Double(durationSeconds))
    }

    private var isRunningEntry: Bool { entry?.isRunning ?? false }

    private var canSave: Bool {
        guard projectId != 0 else { return false }
        if isRunningEntry { return true }        // a running entry only needs its start and project
        guard let durationSeconds else { return false }
        return durationSeconds > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry == nil ? "Add Entry" : "Edit Entry")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 14)

            Form {
                Picker("Project", selection: $projectId) {
                    ForEach(model.projects) { project in
                        Text(project.displayName).tag(project.id)
                    }
                }

                if isRunningEntry {
                    DatePicker("Start", selection: $start)
                    LabeledContent("End") {
                        Text("Still running — set when you stop the timer.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Enter as", selection: $mode) {
                        ForEach(EntryInputMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    DatePicker(mode == .duration ? "Started" : "Start", selection: $start)

                    switch mode {
                    case .startEnd:
                        DatePicker("End", selection: $end)
                    case .duration:
                        durationFields
                    }

                    LabeledContent("Total") { totalReadout }
                }

                TextField("Description", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.grouped)
            .onChange(of: mode) { _, newMode in syncFields(for: newMode) }

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 6)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(entry == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 470)
        .onAppear(perform: loadOnce)
    }

    /// Hours and minutes side by side. Either may be left blank.
    private var durationFields: some View {
        LabeledContent("Duration") {
            HStack(spacing: 6) {
                TextField("0", text: $hoursText)
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                Text("h").foregroundStyle(.secondary)

                TextField("0", text: $minutesText)
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                Text("m").foregroundStyle(.secondary)

                Spacer()
            }
        }
    }

    /// The decimal-hours conversion, which is the number that reaches an invoice.
    @ViewBuilder
    private var totalReadout: some View {
        if let seconds = durationSeconds, seconds > 0 {
            HStack(spacing: 8) {
                Text(Format.hours(seconds))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text("hours")
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(Format.duration(seconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if mode == .duration, let resolvedEnd {
                    Text("· ends \(Format.timeOfDay.string(from: resolvedEnd))")
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private var warning: String? {
        guard !isRunningEntry else { return nil }
        switch mode {
        case .startEnd:
            return end < start ? "The end time is before the start time." : nil
        case .duration:
            if durationSeconds == nil { return "Enter hours and minutes as plain numbers." }
            return durationSeconds == 0 ? "Enter a duration greater than zero." : nil
        }
    }

    /// Carries the current value across when the input style changes, so
    /// switching modes never silently discards what was typed.
    private func syncFields(for newMode: EntryInputMode) {
        switch newMode {
        case .duration:
            let seconds = max(0, Int(end.timeIntervalSince(start)))
            hoursText = seconds / 3600 == 0 ? "" : String(seconds / 3600)
            minutesText = String((seconds % 3600) / 60)
        case .startEnd:
            if let seconds = Format.parseDuration(hours: hoursText, minutes: minutesText) {
                end = start.addingTimeInterval(Double(seconds))
            }
        }
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        if let entry {
            projectId = entry.projectId
            start = entry.startedAt
            end = entry.endedAt ?? Date()
            note = entry.note
            // Editing keeps the exact clock times it was recorded with.
            mode = .startEnd
        } else {
            projectId = model.projects.first?.id ?? 0
            // Default to an hour ending now — the common "I forgot to start it" case.
            end = Date()
            start = end.addingTimeInterval(-3600)
            mode = .duration
            hoursText = "1"
            minutesText = "0"
        }
    }

    private func save() {
        if let entry {
            // A running entry stays running: keep its nil end rather than stamping one on.
            let newEnd: Date? = entry.isRunning ? nil : resolvedEnd
            model.updateEntry(id: entry.id, projectId: projectId, start: start, end: newEnd, note: note)
        } else if let resolvedEnd {
            model.addManualEntry(projectId: projectId, start: start, end: resolvedEnd, note: note)
        }
        dismiss()
    }
}

import SwiftUI

struct TimersView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var noteDrafts: [Int64: String] = [:]

    private var filteredProjects: [Project] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.projects }
        return model.projects.filter {
            $0.name.lowercased().contains(query) || $0.clientName.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Timers", subtitle: "Several can run at once — start as many as you need.") {
                Button("Stop All") { model.stopAll() }
                    .disabled(model.running.isEmpty)
            }

            if model.projects.isEmpty {
                EmptyHint(
                    icon: "person.2",
                    title: "No projects yet",
                    message: "Add a client and at least one project in Clients & Projects, then you can start timing against it."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !model.running.isEmpty { runningSection }
                        startSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - Running

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Running")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(model.running) { entry in
                RunningCard(
                    entry: entry,
                    note: Binding(
                        get: { noteDrafts[entry.id] ?? entry.note },
                        set: { noteDrafts[entry.id] = $0 }
                    ),
                    onCommitNote: { commitNote(for: entry) },
                    onStop: {
                        commitNote(for: entry)
                        model.stopTimer(entry)
                        noteDrafts[entry.id] = nil
                    },
                    onDiscard: {
                        model.cancelTimer(entry)
                        noteDrafts[entry.id] = nil
                    }
                )
                .environmentObject(model)
            }
        }
    }

    /// Saves the in-progress description without stopping the clock.
    private func commitNote(for entry: Entry) {
        guard let draft = noteDrafts[entry.id], draft != entry.note else { return }
        model.updateEntry(id: entry.id, projectId: entry.projectId, start: entry.startedAt, end: nil, note: draft)
    }

    // MARK: - Start

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Start a timer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 400), spacing: 10)], spacing: 10) {
                ForEach(filteredProjects) { project in
                    ProjectStartTile(project: project, todayEntries: model.todayEntries(forProject: project.id))
                        .environmentObject(model)
                }
            }
        }
    }
}

// MARK: - Cards

private struct RunningCard: View {
    @EnvironmentObject var model: AppModel
    let entry: Entry
    @Binding var note: String
    let onCommitNote: () -> Void
    let onStop: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.projectName).font(.headline)
                Text(entry.clientName).font(.caption).foregroundStyle(.secondary)
                TextField("What are you working on?", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onCommitNote)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                LiveDuration(entry: entry)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("started \(Format.timeOfDay.string(from: entry.startedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)

                Button("Discard", role: .destructive, action: onDiscard)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.red.opacity(0.25)))
    }
}

private struct ProjectStartTile: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    /// Time already logged against this project today, so you can see where the day went.
    let todayEntries: [Entry]

    private var isRunning: Bool { model.isRunning(projectId: project.id) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(project.clientName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if !todayEntries.isEmpty {
                LiveDuration(entries: todayEntries, style: .compact)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                model.startTimer(projectId: project.id)
            } label: {
                Image(systemName: isRunning ? "plus.circle" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isRunning ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(isRunning ? "Start a second timer on this project" : "Start timing \(project.name)")
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
}

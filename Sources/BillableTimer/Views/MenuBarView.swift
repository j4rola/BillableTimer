import SwiftUI
import AppKit

/// The status-bar panel: start and stop without bringing the window forward.
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    /// Supplied by `MenuBarController`, which owns the window-reopening logic.
    var onOpenMain: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if !model.running.isEmpty {
                runningList
                Divider()
            }

            quickStart
            Divider()
            footer
        }
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Today").font(.caption).foregroundStyle(.secondary)
                LiveDuration(entries: model.todayEntries, style: .compact)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            Spacer()
            if !model.running.isEmpty {
                Button("Stop All") { model.stopAll() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var runningList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RUNNING")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(model.running) { entry in
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.projectName).font(.callout).lineLimit(1)
                        Text(entry.clientName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    LiveDuration(entry: entry)
                        .font(.callout)
                    Button {
                        model.stopTimer(entry)
                    } label: {
                        Image(systemName: "stop.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .padding(.bottom, 4)
        }
    }

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("START")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if model.projects.isEmpty {
                Text("Add a client and project in the main window first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.projects.prefix(12)) { project in
                            Button {
                                model.startTimer(projectId: project.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "play.circle")
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(project.name).font(.callout).lineLimit(1)
                                        Text(project.clientName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .padding(.bottom, 4)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open BillableTimer") { onOpenMain() }
                .controlSize(.small)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

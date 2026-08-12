import SwiftUI

struct ClientsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedClientId: Int64?
    @State private var editingClient: Client?
    @State private var creatingClient = false
    @State private var editingProject: Project?
    @State private var creatingProjectFor: Int64?

    private var selectedClient: Client? {
        model.clients.first { $0.id == selectedClientId } ?? model.clients.first
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Clients & Projects", subtitle: "Rates live on the client; a project can override its own.") {
                Button {
                    creatingClient = true
                } label: {
                    Label("Add Client", systemImage: "plus")
                }
            }

            if model.clients.isEmpty {
                EmptyHint(
                    icon: "person.2",
                    title: "No clients yet",
                    message: "Add your first client and its hourly rate. Then add one or more projects to bill time against."
                )
            } else {
                HSplitView {
                    clientList
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                    projectDetail
                        .frame(minWidth: 380)
                }
            }
        }
        .sheet(isPresented: $creatingClient) {
            ClientEditor(client: nil).environmentObject(model)
        }
        .sheet(item: $editingClient) { client in
            ClientEditor(client: client).environmentObject(model)
        }
        .sheet(item: $editingProject) { project in
            ProjectEditor(clientId: project.clientId, project: project).environmentObject(model)
        }
        .sheet(isPresented: Binding(
            get: { creatingProjectFor != nil },
            set: { if !$0 { creatingProjectFor = nil } }
        )) {
            if let clientId = creatingProjectFor {
                ProjectEditor(clientId: clientId, project: nil).environmentObject(model)
            }
        }
    }

    private var clientList: some View {
        List(selection: $selectedClientId) {
            ForEach(model.clients) { client in
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.name).font(.subheadline.weight(.medium))
                    Text("\(Format.money(client.hourlyRateCents))/h · \(model.projects(for: client.id).count) project\(model.projects(for: client.id).count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(client.id)
                .contextMenu {
                    Button("Edit…") { editingClient = client }
                    Button("Add Project…") { creatingProjectFor = client.id }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteClient(client) }
                }
            }
        }
    }

    @ViewBuilder
    private var projectDetail: some View {
        if let client = selectedClient {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(client.name).font(.title3.weight(.semibold))
                        Text("Default rate \(Format.money(client.hourlyRateCents))/h")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !client.address.isEmpty {
                            Text(client.address)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(3)
                        }
                    }
                    Spacer()
                    Button("Edit Client") { editingClient = client }
                    Button {
                        creatingProjectFor = client.id
                    } label: {
                        Label("Add Project", systemImage: "plus")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                Divider()

                let projects = model.projects(for: client.id)
                if projects.isEmpty {
                    EmptyHint(
                        icon: "folder",
                        title: "No projects for \(client.name)",
                        message: "A project is the project or case you bill against. Add one to start timing."
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(projects) { project in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project.name).font(.subheadline)
                                        Text(project.hourlyRateCents == nil
                                             ? "Client rate · \(Format.money(project.effectiveRateCents))/h"
                                             : "Custom rate · \(Format.money(project.effectiveRateCents))/h")
                                            .font(.caption)
                                            .foregroundStyle(project.hourlyRateCents == nil ? Color.secondary : Color.orange)
                                    }
                                    Spacer()
                                    if model.isRunning(projectId: project.id) {
                                        Circle().fill(.red).frame(width: 7, height: 7)
                                    }
                                    Button("Start") { model.startTimer(projectId: project.id) }
                                        .buttonStyle(.bordered)
                                    Menu {
                                        Button("Edit…") { editingProject = project }
                                        Divider()
                                        Button("Delete", role: .destructive) { model.deleteProject(project) }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .frame(width: 28)
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                Divider()
                            }
                        }
                    }
                }
            }
        } else {
            EmptyHint(icon: "person", title: "Select a client", message: "Pick a client on the left to see its projects.")
        }
    }
}

// MARK: - Editors

struct ClientEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let client: Client?

    @State private var name = ""
    @State private var rateText = ""
    @State private var address = ""
    @State private var notes = ""
    @State private var archived = false
    @State private var loaded = false

    private var rateCents: Int? { Format.parseMoney(rateText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(client == nil ? "New Client" : "Edit Client")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 12)

            Form {
                TextField("Name", text: $name)
                TextField("Hourly rate", text: $rateText, prompt: Text("250.00"))
                TextField("Billing address", text: $address, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(1...3)
                if client != nil {
                    Toggle("Archived", isOn: $archived)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || rateCents == nil)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: loadOnce)
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        guard let client else { return }
        name = client.name
        rateText = String(format: "%.2f", Double(client.hourlyRateCents) / 100)
        address = client.address
        notes = client.notes
        archived = client.archived
    }

    private func save() {
        guard let rateCents else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if var client {
            client.name = trimmed
            client.hourlyRateCents = rateCents
            client.address = address
            client.notes = notes
            client.archived = archived
            model.updateClient(client)
        } else {
            model.createClient(name: trimmed, rateCents: rateCents, address: address, notes: notes)
        }
        dismiss()
    }
}

struct ProjectEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let clientId: Int64
    let project: Project?

    @State private var name = ""
    @State private var useCustomRate = false
    @State private var rateText = ""
    @State private var archived = false
    @State private var loaded = false

    private var clientRateCents: Int {
        model.clients.first { $0.id == clientId }?.hourlyRateCents ?? 0
    }

    private var rateCents: Int? {
        useCustomRate ? Format.parseMoney(rateText) : nil
    }

    private var rateIsValid: Bool {
        !useCustomRate || Format.parseMoney(rateText) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(project == nil ? "New Project" : "Edit Project")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 12)

            Form {
                TextField("Project name", text: $name, prompt: Text("Acme acquisition"))
                Toggle("Override the client rate", isOn: $useCustomRate)
                if useCustomRate {
                    TextField("Hourly rate", text: $rateText, prompt: Text("300.00"))
                } else {
                    LabeledContent("Rate") {
                        Text("\(Format.money(clientRateCents))/h (from client)")
                            .foregroundStyle(.secondary)
                    }
                }
                if project != nil {
                    Toggle("Archived", isOn: $archived)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !rateIsValid)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: loadOnce)
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        guard let project else { return }
        name = project.name
        archived = project.archived
        if let override = project.hourlyRateCents {
            useCustomRate = true
            rateText = String(format: "%.2f", Double(override) / 100)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if var project {
            project.name = trimmed
            project.hourlyRateCents = rateCents
            project.archived = archived
            model.updateProject(project)
        } else {
            model.createProject(clientId: clientId, name: trimmed, rateCents: rateCents)
        }
        dismiss()
    }
}

import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    private var currentPeriod: DateRange {
        Periods.twoWeeks(
            containing: Date(),
            anchor: model.settings.periodAnchor,
            firstWeekday: model.settings.firstWeekday
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Settings", subtitle: "Business identity, billing periods, and where your data lives.") {
                Button("Save") { model.saveSettings() }
                    .buttonStyle(.borderedProminent)
            }

            Form {
                Section("Your business") {
                    TextField("Name", text: $model.settings.businessName, prompt: Text("Jane Froula, Attorney at Law"))
                    TextField("Address", text: $model.settings.businessAddress, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Email", text: $model.settings.businessEmail)
                }

                Section("Invoices") {
                    TextField("Number prefix", text: $model.settings.invoicePrefix, prompt: Text("INV-"))
                    Stepper(
                        "Next invoice number: \(model.settings.nextInvoiceNumber)",
                        value: $model.settings.nextInvoiceNumber,
                        in: 1...999_999
                    )
                    TextField("Payment terms", text: $model.settings.invoiceTerms, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section("Billing periods") {
                    Picker("Week starts on", selection: $model.settings.firstWeekday) {
                        Text("Sunday").tag(1)
                        Text("Monday").tag(2)
                    }

                    DatePicker(
                        "Two-week periods start from",
                        selection: $model.settings.periodAnchor,
                        displayedComponents: .date
                    )

                    LabeledContent("Current period") {
                        Text("\(Format.compactDate.string(from: currentPeriod.start)) – \(Format.shortDate.string(from: currentPeriod.lastDay))")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Data") {
                    LabeledContent("Database") {
                        HStack(spacing: 8) {
                            Text(model.store.databasePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: model.store.databasePath)]
                                )
                            }
                        }
                    }
                    Text("Everything is stored in this one SQLite file. Back it up and your entire billing history travels with it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        // Settings changes only take effect once saved, so reporting can't shift underfoot.
        .onDisappear { model.saveSettings() }
    }
}

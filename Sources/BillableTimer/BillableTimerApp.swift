import SwiftUI
import AppKit

@main
struct BillableTimerApp: App {
    @StateObject private var model = Bootstrap.makeModel()
    @StateObject private var bridge = WindowBridge()
    /// The status bar item is plain AppKit — see `MenuBarController` for why.
    @State private var menuBar: MenuBarController?

    var body: some Scene {
        Window("BillableTimer", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.clock)
                .environmentObject(bridge)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    if menuBar == nil {
                        menuBar = MenuBarController(model: model, bridge: bridge)
                    }
                }
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Stop All Timers") { model.stopAll() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(model.running.isEmpty)
            }
        }
    }
}

enum Bootstrap {
    /// The database is the whole app; if it can't open, say so plainly and quit
    /// rather than running in a half-broken state.
    @MainActor
    static func makeModel() -> AppModel {
        do {
            return try AppModel()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "BillableTimer could not open its database"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            exit(1)
        }
    }
}

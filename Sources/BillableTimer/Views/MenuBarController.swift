import AppKit
import Combine
import SwiftUI

/// Lets the status bar reopen the main window even after it has been closed.
/// `OpenWindowAction` can only be read from inside a Scene, so `RootView` hands
/// its copy over here for the status item to use later.
@MainActor
final class WindowBridge: ObservableObject {
    var openMain: (() -> Void)?
}

/// The status bar item, driven directly by AppKit.
///
/// SwiftUI's `MenuBarExtra` with `.menuBarExtraStyle(.window)` re-lays out
/// continuously even when the panel is closed and its content is a single static
/// `Text` — measured at ~3.5% CPU, forever, on an idle app. (`.menuBarExtraStyle(.menu)`
/// costs nothing but can't host an interactive panel.) An `NSStatusItem` plus an
/// `NSPopover` built on demand gives the same panel for 0% when it isn't open.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let bridge: WindowBridge
    private let statusItem: NSStatusItem
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel, bridge: WindowBridge) {
        self.model = model
        self.bridge = bridge
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            // Monospaced digits stop the item from jittering as the clock ticks.
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover)
        }
        refreshTitle()

        // Redrawing the status item is a string assignment, not a view update.
        model.clock.$now
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &cancellables)
        model.$running
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &cancellables)
    }

    // No deinit: this object lives for the life of the app, and tearing the
    // status item down from an unspecified isolation context is not worth the risk.

    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        if model.running.isEmpty {
            button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "BillableTimer")
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.image = NSImage(systemSymbolName: "largecircle.fill.circle", accessibilityDescription: "Timers running")
            button.title = " \(Format.clock(model.runningSeconds(asOf: model.clock.now)))"
            button.imagePosition = .imageLeading
        }
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(onOpenMain: { [weak self] in self?.openMainWindow() })
                .environmentObject(model)
                .environmentObject(model.clock)
                .frame(width: 320)
        )
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    /// Tear the hosted view down on close so nothing lingers between uses.
    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil
        popover = nil
    }

    private func openMainWindow() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Prefer an existing window; fall back to the Scene's own opener when it
        // has been closed outright.
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            bridge.openMain?()
        }
    }
}

import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemManager: NSObject {
    static let shared = StatusItemManager()

    private var controller: StatusItemController?

    func install(settings: SettingsStore, status: StatusStore) {
        guard controller == nil else { return }
        controller = StatusItemController(settings: settings, status: status)
    }
}

@MainActor
private final class StatusItemController: NSObject, NSPopoverDelegate {
    private let settings: SettingsStore
    private let status: StatusStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let settingsWindowController: SettingsWindowController
    private var statusCancellable: AnyCancellable?

    init(settings: SettingsStore, status: StatusStore) {
        self.settings = settings
        self.status = status
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.settingsWindowController = SettingsWindowController(settings: settings, status: status)
        super.init()

        configureStatusItem()
        configurePopover()
        observeStatus()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = LinkedClipsStatusIcon.image
        button.title = "Clip"
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        updateStatusItemMetadata()
    }

    private func configurePopover() {
        let rootView = MenuContentView {
            self.settingsWindowController.show()
        }
        .environmentObject(settings)
        .environmentObject(status)

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: rootView)
    }

    private func observeStatus() {
        statusCancellable = status.$snapshot.sink { [weak self] _ in
            self?.updateStatusItemMetadata()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func updateStatusItemMetadata() {
        let description = status.snapshot.accessibilityLabel
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
    }
}

@MainActor
private final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let status: StatusStore
    private var controller: NSWindowController?

    init(settings: SettingsStore, status: StatusStore) {
        self.settings = settings
        self.status = status
    }

    func show() {
        if let window = controller?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = SettingsView()
            .environmentObject(settings)
            .environmentObject(status)
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = "ClipSync Control Settings"
        window.setContentSize(NSSize(width: 980, height: 680))
        window.minSize = NSSize(width: 780, height: 600)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        let controller = NSWindowController(window: window)
        self.controller = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        controller = nil
    }
}

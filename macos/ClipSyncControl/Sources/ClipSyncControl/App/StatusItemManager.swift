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
    private let popoverPresentation = StatusItemPopoverPresentation()
    private let settingsWindowController: SettingsWindowController
    private var statusCancellable: AnyCancellable?
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?

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
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        updateStatusItemMetadata()
    }

    private func configurePopover() {
        let rootView = StatusItemPopoverView(
            presentation: popoverPresentation,
            openSettings: { [weak self] in self?.showSettings() }
        )
        .environmentObject(settings)
        .environmentObject(status)

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: rootView)
        popover.contentSize = popoverPresentation.contentSize
    }

    private func observeStatus() {
        statusCancellable = status.$snapshot.sink { [weak self] _ in
            self?.updateStatusItemMetadata()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        let contentSize = StatusItemPopoverLayout.contentSize(for: visibleFrame(for: button))
        popoverPresentation.contentSize = contentSize
        popover.contentSize = contentSize
        popover.contentViewController?.preferredContentSize = contentSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installDismissalMonitors()
    }

    private func showSettings() {
        // Let AppKit finish dismissing the transient popover before the settings window is activated.
        popover.performClose(nil)
        settingsWindowController.show()
    }

    func popoverDidClose(_ notification: Notification) {
        removeDismissalMonitors()
    }

    private func visibleFrame(for button: NSStatusBarButton) -> NSRect {
        button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    }

    // NSPopover's transient behavior handles the normal AppKit dismissal path. These
    // monitors cover clicks routed through another application while the accessory app
    // has no active window, which transient behavior does not consistently receive.
    private func installDismissalMonitors() {
        removeDismissalMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            let mouseLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.dismissPopoverForOutsideMouseDown(at: mouseLocation)
            }
        }
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let mouseLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.dismissPopoverForOutsideMouseDown(at: mouseLocation)
            }
            return event
        }
    }

    private func removeDismissalMonitors() {
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
    }

    private func dismissPopoverForOutsideMouseDown(at mouseLocation: NSPoint) {
        guard popover.isShown else { return }
        let popoverFrame = popover.contentViewController?.view.window?.frame
        let statusItemFrame = statusItemScreenFrame()
        guard StatusItemPopoverDismissal.shouldDismiss(
            mouseLocation: mouseLocation,
            popoverFrame: popoverFrame,
            statusItemFrame: statusItemFrame
        ) else {
            return
        }
        popover.performClose(nil)
    }

    private func statusItemScreenFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func updateStatusItemMetadata() {
        let description = status.snapshot.accessibilityLabel
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
    }

}

@MainActor
private final class StatusItemPopoverPresentation: ObservableObject {
    @Published var contentSize = StatusItemPopoverLayout.defaultContentSize
}

private struct StatusItemPopoverView: View {
    @ObservedObject var presentation: StatusItemPopoverPresentation
    let openSettings: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            MenuContentView(openSettings: openSettings)
        }
        .frame(
            width: presentation.contentSize.width,
            height: presentation.contentSize.height,
            alignment: .topLeading
        )
        .accessibilityIdentifier("clipsync-status-popover")
    }
}

enum StatusItemPopoverLayout {
    static let width: CGFloat = 350
    static let preferredHeight: CGFloat = 620
    static let screenMargin: CGFloat = 24

    static let defaultContentSize = NSSize(width: width, height: preferredHeight)

    static func contentSize(for visibleFrame: NSRect) -> NSSize {
        let availableWidth = max(1, visibleFrame.width - screenMargin)
        let availableHeight = max(1, visibleFrame.height - screenMargin)
        return NSSize(
            width: min(width, availableWidth),
            height: min(preferredHeight, availableHeight)
        )
    }
}

enum StatusItemPopoverDismissal {
    static func shouldDismiss(
        mouseLocation: NSPoint,
        popoverFrame: NSRect?,
        statusItemFrame: NSRect?
    ) -> Bool {
        guard let popoverFrame else { return false }
        return !popoverFrame.contains(mouseLocation) && !(statusItemFrame?.contains(mouseLocation) ?? false)
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

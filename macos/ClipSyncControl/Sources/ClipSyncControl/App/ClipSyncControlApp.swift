import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct ClipSyncControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsStore
    @StateObject private var status: StatusStore

    init() {
        let settings = SettingsStore()
        let status = StatusStore(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _status = StateObject(wrappedValue: status)
        StatusItemManager.shared.install(settings: settings, status: status)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

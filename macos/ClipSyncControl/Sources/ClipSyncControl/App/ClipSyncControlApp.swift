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
        _settings = StateObject(wrappedValue: settings)
        _status = StateObject(wrappedValue: StatusStore(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(settings)
                .environmentObject(status)
        } label: {
            LinkedClipsStatusIcon()
                .accessibilityLabel(status.snapshot.accessibilityLabel)
        }
        .menuBarExtraStyle(.window)

        Window("ClipSync Control Settings", id: "settings") {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(status)
        }
    }
}

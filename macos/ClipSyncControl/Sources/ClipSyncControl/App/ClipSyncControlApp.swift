import AppKit

@main
enum ClipSyncControlApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore?
    private var status: StatusStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let settings = SettingsStore()
        let status = StatusStore(settings: settings)
        self.settings = settings
        self.status = status
        StatusItemManager.shared.install(settings: settings, status: status)
    }
}

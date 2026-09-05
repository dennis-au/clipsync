import AppKit

@main
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

import AppKit

@main
enum CodexQuotaApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let statusBarController = StatusBarController()
        application.delegate = statusBarController
        application.setActivationPolicy(.accessory)

        // The menu-bar controller owns the UI; no placeholder Settings scene is needed.
        withExtendedLifetime(statusBarController) {
            application.run()
        }
    }
}

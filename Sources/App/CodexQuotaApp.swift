import SwiftUI

@main
struct CodexQuotaApp: App {
    @NSApplicationDelegateAdaptor(StatusBarController.self) private var statusBarController

    var body: some Scene {
        Settings { EmptyView() }
    }
}

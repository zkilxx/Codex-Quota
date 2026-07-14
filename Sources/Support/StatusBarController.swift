import AppKit
import Foundation

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = QuotaStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        store.onUpdate = { [weak self] in self?.render() }
        render()
    }

    private func render() {
        statusItem.button?.title = statusTitle
        statusItem.button?.toolTip = tooltip
        statusItem.menu = makeMenu()
    }

    private var statusTitle: String {
        guard let window = store.snapshot?.primary else {
            return store.isRefreshing ? "Codex 更新中…" : "Codex --"
        }
        let reset = window.resetDate.map(relativeTime) ?? "--"
        return "Codex \(window.remainingPercent)% · \(reset)"
    }

    private var tooltip: String {
        if let error = store.errorMessage { return error }
        return "Codex 限额与刷新时间"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if let snapshot = store.snapshot {
            addWindow(snapshot.primary, fallback: "主要额度", to: menu)
            addWindow(snapshot.secondary, fallback: "次要额度", to: menu)
        } else if let error = store.errorMessage {
            menu.addItem(withTitle: error, action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "正在读取 Codex 限额…", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        let refresh = menu.addItem(withTitle: store.isRefreshing ? "正在刷新…" : "立即刷新", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !store.isRefreshing
        let usage = menu.addItem(withTitle: "打开 Codex 用量设置", action: #selector(openUsage), keyEquivalent: "")
        usage.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Codex Quota", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        return menu
    }

    private func addWindow(_ window: RateLimitWindow?, fallback: String, to menu: NSMenu) {
        guard let window else { return }
        let duration = window.windowDurationMins.map { "\($0) 分钟额度" } ?? fallback
        let reset = window.resetDate.map { "，刷新 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        menu.addItem(withTitle: "\(duration)：剩余 \(window.remainingPercent)%\(reset)", action: nil, keyEquivalent: "")
    }

    private func relativeTime(to date: Date) -> String {
        let interval = max(0, Int(date.timeIntervalSinceNow))
        if interval >= 86_400 { return "\(interval / 86_400)天" }
        if interval >= 3_600 { return "\(interval / 3_600)时" }
        return "\(max(1, interval / 60))分"
    }

    @objc private func refresh() { store.refresh() }
    @objc private func openUsage() { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!) }
    @objc private func quit() { NSApp.terminate(nil) }
}

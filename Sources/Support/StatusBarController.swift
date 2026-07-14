import AppKit
import Foundation

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate {
    private struct QuotaOption {
        let title: String
        let shortTitle: String
        let minutes: Int64
        let preferenceKey: String
    }

    private let quotaOptions = [
        QuotaOption(title: "5小时额度", shortTitle: "5时", minutes: 300, preferenceKey: "showFiveHourQuota"),
        QuotaOption(title: "1周额度", shortTitle: "1周", minutes: 10_080, preferenceKey: "showWeeklyQuota"),
        QuotaOption(title: "1月额度", shortTitle: "1月", minutes: 43_200, preferenceKey: "showMonthlyQuota")
    ]
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = QuotaStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        store.onUpdate = { [weak self] in self?.render() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
        render()
        if CommandLine.arguments.contains("--screenshot-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
        }
    }

    private func render() {
        statusItem.button?.title = statusTitle
        statusItem.button?.toolTip = tooltip
        statusItem.menu = makeMenu()
    }

    private var statusTitle: String {
        guard let snapshot = store.snapshot else {
            return store.isRefreshing ? "Codex 更新中…" : "Codex --"
        }
        var parts = quotaOptions.compactMap { option -> String? in
            guard isVisible(option), let window = window(for: option, in: snapshot) else { return nil }
            if preference("showResetCountdown") {
                let reset = window.resetDate.map(relativeTime) ?? "--"
                return "\(option.shortTitle) \(window.remainingPercent)% · \(reset)"
            }
            return "\(option.shortTitle) \(window.remainingPercent)%"
        }
        if preference("showTodayTokens"), let tokens = store.todayTokens {
            parts.insert("今日 \(compactTokens(tokens))", at: 0)
        }
        return parts.isEmpty ? "Codex --" : "Codex " + parts.joined(separator: " · ")
    }

    private var tooltip: String {
        if let error = store.errorMessage { return error }
        return "Codex 限额与刷新时间"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if let error = store.errorMessage, store.snapshot == nil {
            menu.addItem(withTitle: error, action: nil, keyEquivalent: "")
        }
        let tokenTitle = store.todayTokens.map { "今日累计 Token：\(formattedTokens($0))" } ?? "今日累计 Token：正在读取…"
        let tokenItem = menu.addItem(withTitle: tokenTitle, action: #selector(togglePreference(_:)), keyEquivalent: "")
        tokenItem.target = self
        tokenItem.representedObject = "showTodayTokens"
        tokenItem.state = preference("showTodayTokens") ? .on : .off
        menu.addItem(.separator())
        for option in quotaOptions { addQuotaOption(option, snapshot: store.snapshot, to: menu) }
        let countdown = menu.addItem(withTitle: "显示刷新倒计时", action: #selector(togglePreference(_:)), keyEquivalent: "")
        countdown.target = self
        countdown.representedObject = "showResetCountdown"
        countdown.state = preference("showResetCountdown") ? .on : .off
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

    private func addQuotaOption(_ option: QuotaOption, snapshot: RateLimitSnapshot?, to menu: NSMenu) {
        let detail: String
        if let snapshot, let window = window(for: option, in: snapshot) {
            let reset = window.resetDate.map { "，刷新 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            detail = "剩余 \(window.remainingPercent)%\(reset)"
        } else {
            detail = store.isRefreshing ? "正在读取…" : "暂无数据"
        }
        let item = menu.addItem(withTitle: "\(option.title)：\(detail)", action: #selector(togglePreference(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = option.preferenceKey
        item.state = isVisible(option) ? .on : .off
    }

    private func durationLabel(_ minutes: Int64) -> String {
        switch minutes {
        case 10_080: "1周额度"
        case 1_440: "1天额度"
        default: "\(minutes) 分钟额度"
        }
    }

    private func window(for option: QuotaOption, in snapshot: RateLimitSnapshot) -> RateLimitWindow? {
        [snapshot.primary, snapshot.secondary].compactMap { $0 }.first { $0.windowDurationMins == option.minutes }
    }

    private func isVisible(_ option: QuotaOption) -> Bool {
        preference(option.preferenceKey)
    }

    private func preference(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private func relativeTime(to date: Date) -> String {
        let interval = max(0, Int(date.timeIntervalSinceNow))
        if interval >= 86_400 { return "\(interval / 86_400)天" }
        if interval >= 3_600 { return "\(interval / 3_600)时" }
        return "\(max(1, interval / 60))分"
    }

    private func compactTokens(_ tokens: Int64) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    private func formattedTokens(_ tokens: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
    }

    @objc private func refresh() { store.refresh() }
    @objc private func openUsage() { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!) }
    @objc private func togglePreference(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(!preference(key), forKey: key)
        render()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

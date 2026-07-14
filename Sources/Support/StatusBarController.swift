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

    private struct LabelDefinition {
        let title: String
        let key: String
        let defaultValue: String
    }

    private let quotaOptions = [
        QuotaOption(title: "5小时额度", shortTitle: "5时", minutes: 300, preferenceKey: "showFiveHourQuota"),
        QuotaOption(title: "1周额度", shortTitle: "1周", minutes: 10_080, preferenceKey: "showWeeklyQuota"),
        QuotaOption(title: "1月额度", shortTitle: "1月", minutes: 43_200, preferenceKey: "showMonthlyQuota")
    ]
    private let labelDefinitions = [
        LabelDefinition(title: "应用前缀", key: "customAppLabel", defaultValue: "Codex"),
        LabelDefinition(title: "今日", key: "customTodayLabel", defaultValue: "今日"),
        LabelDefinition(title: "本月", key: "customMonthLabel", defaultValue: "本月"),
        LabelDefinition(title: "本年", key: "customYearLabel", defaultValue: "本年"),
        LabelDefinition(title: "5小时", key: "customFiveHourLabel", defaultValue: "5时"),
        LabelDefinition(title: "1周", key: "customWeekLabel", defaultValue: "1周"),
        LabelDefinition(title: "1月", key: "customMonthQuotaLabel", defaultValue: "1月")
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
        var parts: [String] = []
        if preference("showTodayTokens"), let tokens = store.todayTokens {
            parts.append("\(displayLabel(key: "customTodayLabel", defaultValue: "今日")) \(compactTokens(tokens))")
        }
        if preference("showMonthTokens", defaultValue: false), let tokens = store.monthTokens {
            parts.append("\(displayLabel(key: "customMonthLabel", defaultValue: "本月")) \(compactTokens(tokens))")
        }
        if preference("showYearTokens", defaultValue: false), let tokens = store.yearTokens {
            parts.append("\(displayLabel(key: "customYearLabel", defaultValue: "本年")) \(compactTokens(tokens))")
        }
        parts += quotaOptions.compactMap { option -> String? in
            guard isVisible(option), let window = window(for: option, in: snapshot) else { return nil }
            let title = quotaDisplayLabel(option)
            if preference("showResetCountdown") {
                let reset = window.resetDate.map(relativeTime) ?? "--"
                return "\(title) \(window.remainingPercent)% · \(reset)"
            }
            return "\(title) \(window.remainingPercent)%"
        }
        let appLabel = displayLabel(key: "customAppLabel", defaultValue: "Codex")
        return parts.isEmpty ? "\(appLabel) --" : appLabel + " " + parts.joined(separator: " · ")
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
        addTokenItem(title: "本月累计 Token", tokens: store.monthTokens, key: "showMonthTokens", defaultValue: false, to: menu)
        addTokenItem(title: "本年累计 Token", tokens: store.yearTokens, key: "showYearTokens", defaultValue: false, to: menu)
        menu.addItem(.separator())
        for option in quotaOptions { addQuotaOption(option, snapshot: store.snapshot, to: menu) }
        let countdown = menu.addItem(withTitle: "显示刷新倒计时", action: #selector(togglePreference(_:)), keyEquivalent: "")
        countdown.target = self
        countdown.representedObject = "showResetCountdown"
        countdown.state = preference("showResetCountdown") ? .on : .off
        addLabelMenu(to: menu)
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

    private func addTokenItem(title: String, tokens: Int64?, key: String, defaultValue: Bool, to menu: NSMenu) {
        let detail = tokens.map(formattedTokens) ?? "正在读取…"
        let item = menu.addItem(withTitle: "\(title)：\(detail)", action: #selector(togglePreference(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = key
        item.state = preference(key, defaultValue: defaultValue) ? .on : .off
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

    private func quotaDisplayLabel(_ option: QuotaOption) -> String {
        switch option.minutes {
        case 300: displayLabel(key: "customFiveHourLabel", defaultValue: option.shortTitle)
        case 10_080: displayLabel(key: "customWeekLabel", defaultValue: option.shortTitle)
        case 43_200: displayLabel(key: "customMonthQuotaLabel", defaultValue: option.shortTitle)
        default: option.shortTitle
        }
    }

    private func displayLabel(key: String, defaultValue: String) -> String {
        guard preference("useCustomLabels", defaultValue: false) else { return defaultValue }
        let value = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultValue : value
    }

    private func addLabelMenu(to menu: NSMenu) {
        let parent = NSMenuItem(title: "状态栏文字", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "状态栏文字")
        let defaults = submenu.addItem(withTitle: "默认文字", action: #selector(useDefaultLabels), keyEquivalent: "")
        defaults.target = self
        defaults.state = preference("useCustomLabels", defaultValue: false) ? .off : .on
        let custom = submenu.addItem(withTitle: "自定义文字…", action: #selector(editCustomLabels), keyEquivalent: "")
        custom.target = self
        custom.state = preference("useCustomLabels", defaultValue: false) ? .on : .off
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func preference(_ key: String, defaultValue: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
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
        let defaultValue = key == "showMonthTokens" || key == "showYearTokens" ? false : true
        UserDefaults.standard.set(!preference(key, defaultValue: defaultValue), forKey: key)
        render()
    }
    @objc private func useDefaultLabels() {
        UserDefaults.standard.set(false, forKey: "useCustomLabels")
        render()
    }
    @objc private func editCustomLabels() {
        let alert = NSAlert()
        alert.messageText = "自定义状态栏文字"
        alert.informativeText = "留空将使用默认文字。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let grid = NSGridView()
        grid.rowSpacing = 7
        grid.columnSpacing = 10
        var fields: [NSTextField] = []
        for definition in labelDefinitions {
            let title = NSTextField(labelWithString: definition.title)
            title.alignment = .right
            let field = NSTextField(string: UserDefaults.standard.string(forKey: definition.key) ?? definition.defaultValue)
            field.placeholderString = definition.defaultValue
            field.widthAnchor.constraint(equalToConstant: 170).isActive = true
            grid.addRow(with: [title, field])
            fields.append(field)
        }
        alert.accessoryView = grid
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for (definition, field) in zip(labelDefinitions, fields) {
            UserDefaults.standard.set(field.stringValue, forKey: definition.key)
        }
        UserDefaults.standard.set(true, forKey: "useCustomLabels")
        render()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

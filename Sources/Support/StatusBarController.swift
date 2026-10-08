import AppKit
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private struct QuotaOption {
        let shortTitle: String
        let minutes: Int64
        let preferenceKey: String
    }

    private let quotaOptions = [
        QuotaOption(shortTitle: "5时", minutes: 300, preferenceKey: "showFiveHourQuota"),
        QuotaOption(shortTitle: "1周", minutes: 10_080, preferenceKey: "showWeeklyQuota"),
        QuotaOption(shortTitle: "1月", minutes: 43_200, preferenceKey: "showMonthlyQuota")
    ]
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store = QuotaStore()
    private weak var activeEffectView: NSVisualEffectView?
    private var pendingStatusItemUpdate = false
    private var systemAppearanceObservation: NSKeyValueObservation?
    private var resetCreditCountdownTimer: Timer?
    private var resetCreditAutomation: ResetCreditAutomationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.hasFullSizeContent = true
        popover.contentSize = NSSize(width: 420, height: fittedPopoverHeight(PanelLayoutMetrics.overviewHeight))

        systemAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard UserDefaults.standard.string(forKey: "interfaceAppearance") ?? "system" == "system" else { return }
                self?.applyInterfaceAppearance(to: self?.activeEffectView)
            }
        }

        store.onUpdate = { [weak self] in self?.render() }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.store.reloadRemoteSyncConfiguration()
                self.configureResetCreditCountdownTimer()
                self.resetCreditAutomation?.preferencesDidChange()
                self.render()
            }
        }
        NotificationCenter.default.addObserver(
            forName: RemoteSyncConfigurationStore.configurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.store.reloadRemoteSyncConfiguration() }
        }
        render()
        configureResetCreditCountdownTimer()
        let diagnosticsOnly = CommandLine.arguments.contains { ["--render-snapshot", "--screenshot-menu", "--edit-labels", "--custom-labels", "--preview-reset-confirmation"].contains($0) }
        if !diagnosticsOnly {
            let notifier = ResetCreditNotificationService()
            notifier.onOpen = { [weak self] in self?.showPopover(initialPage: .overview) }
            let automation = ResetCreditAutomationController(store: store, notifier: notifier)
            notifier.onPermissionGranted = { [weak automation] in automation?.notificationPermissionGranted() }
            resetCreditAutomation = automation
            automation.start()
        }
        if CommandLine.arguments.contains("--preview-reset-confirmation") {
            Task {
                let preview = ResetCreditConfirmationService(previewOnly: true)
                let card = RateLimitResetCredit(id: "confirmation-preview", resetType: "codexRateLimits", status: "available", grantedAt: Int64(Date.now.timeIntervalSince1970), expiresAt: Int64(Date.now.addingTimeInterval(180).timeIntervalSince1970), title: nil, description: nil)
                let approved = await preview.confirmUse(of: card)
                if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--confirmation-report-path=") }),
                   let data = try? JSONSerialization.data(withJSONObject: ["approved": approved, "previewOnly": true, "realCreditsConsumed": 0], options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: String(argument.dropFirst("--confirmation-report-path=".count))), options: .atomic)
                }
                NSApplication.shared.terminate(nil)
            }
        }
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--automation-report-path=") }) {
            let path = String(argument.dropFirst("--automation-report-path=".count))
            Task { [weak self] in
                guard let self else { return }
                for _ in 0..<40 {
                    if self.store.resetCredits != nil { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                let first = self.store.resetCredits?.availableFullResetCredits(at: .now).first?.expirationDate
                let report: [String: Any] = [
                    "running": self.resetCreditAutomation != nil,
                    "reminderEnabled": self.preference("remindExpiringResetCredits"),
                    "autoUseEnabled": self.preference("autoUseExpiringResetCredits"),
                    "requiresConfirmation": true,
                    "notificationAuthorization": settings.authorizationStatus.rawValue,
                    "firstExpiration": first?.timeIntervalSince1970 ?? 0,
                    "reminderAt": first?.addingTimeInterval(-600).timeIntervalSince1970 ?? 0,
                    "confirmationAt": first?.addingTimeInterval(-180).timeIntervalSince1970 ?? 0
                ]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }
        }

        if CommandLine.arguments.contains("--render-snapshot") {
            let initialPage: QuotaMenuPage
            if CommandLine.arguments.contains("--custom-labels") {
                initialPage = .customLabels
            } else if CommandLine.arguments.contains("--about") {
                initialPage = .about
            } else if CommandLine.arguments.contains("--edit-labels") {
                initialPage = .statusBarDisplay
            } else {
                initialPage = .overview
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.renderSnapshotWhenReady(page: initialPage)
            }
        } else if CommandLine.arguments.contains("--screenshot-menu") {
            let initialPage: QuotaMenuPage
            if CommandLine.arguments.contains("--custom-labels") {
                initialPage = .customLabels
            } else if CommandLine.arguments.contains("--about") {
                initialPage = .about
            } else if CommandLine.arguments.contains("--edit-labels") {
                initialPage = .statusBarDisplay
            } else {
                initialPage = .overview
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.showPopover(initialPage: initialPage)
            }
        } else if CommandLine.arguments.contains("--edit-labels") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.showPopover(initialPage: .statusBarDisplay)
            }
        }
    }

    private func render() {
        if popover.isShown {
            pendingStatusItemUpdate = true
        } else {
            updateStatusItem()
        }
        applyInterfaceAppearance(to: activeEffectView)
    }

    private func updateStatusItem() {
        let title = statusTitle
        if statusItem.button?.title != title {
            statusItem.button?.title = title
        }
        statusItem.button?.toolTip = tooltip
        pendingStatusItemUpdate = false
    }

    private func configureResetCreditCountdownTimer() {
        guard preference("showResetCreditCountdown", defaultValue: false) else {
            guard let timer = resetCreditCountdownTimer else { return }
            timer.invalidate()
            resetCreditCountdownTimer = nil
            updateStatusItem()
            return
        }
        guard resetCreditCountdownTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        resetCreditCountdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateStatusItem()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(initialPage: .overview)
        }
    }

    private func showPopover(initialPage: QuotaMenuPage) {
        guard let button = statusItem.button else { return }
        popover.contentSize = NSSize(width: 420, height: fittedPopoverHeight(preferredHeight(for: initialPage)))
        let view = PremiumQuotaMenuView(
            store: store,
            initialPage: initialPage,
            onClose: { [weak self] in self?.popover.performClose(nil) },
            onPreferredHeightChange: { [weak self] height in
                guard let self else { return }
                self.resizePopover(to: height)
            }
        )
        popover.contentViewController = makeFrostedContentController(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)

        DispatchQueue.main.async { [weak self] in
            guard let window = self?.popover.contentViewController?.view.window else { return }
            window.makeKey()
            window.orderFrontRegardless()
        }
    }

    private func resizePopover(to height: CGFloat) {
        let height = fittedPopoverHeight(height)
        guard abs(popover.contentSize.height - height) > 0.5 else { return }
        // NSPopover owns its positioning window and natively animates contentSize
        // changes while `animates` is enabled. A single assignment preserves the
        // status-item anchor; custom frame loops cause AppKit to reposition twice.
        popover.contentSize = NSSize(width: 420, height: height)
    }

    private func fittedPopoverHeight(_ requestedHeight: CGFloat) -> CGFloat {
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return requestedHeight }
        return min(requestedHeight, max(1, screen.visibleFrame.height - 16))
    }

    private func makeFrostedContentController<Content: View>(rootView: Content) -> NSViewController {
        let effectView = NSVisualEffectView()
        effectView.material = .menu
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = false
        applyInterfaceAppearance(to: effectView)
        activeEffectView = effectView

        let hostingController = NSHostingController(rootView: rootView)
        // Preserve SwiftUI's standard sizing metrics, but never publish them as
        // the popover controller's preferred size.
        hostingController.sizingOptions = .standardBounds
        let hostingView = hostingController.view
        hostingView.frame = effectView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        effectView.addSubview(hostingView)

        let container = NSViewController()
        container.view = effectView
        container.addChild(hostingController)
        return container
    }

    private func renderSnapshotWhenReady(page: QuotaMenuPage, attempt: Int = 0) {
        let includesStatusReport = CommandLine.arguments.contains { $0.hasPrefix("--status-report-path=") }
        if (page == .overview || includesStatusReport), store.isRefreshing, attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.renderSnapshotWhenReady(page: page, attempt: attempt + 1)
            }
            return
        }
        renderSnapshot(page: page)
    }

    private func renderSnapshot(page: QuotaMenuPage) {
        let height = preferredHeight(for: page)
        let scheme: ColorScheme = UserDefaults.standard.string(forKey: "interfaceAppearance") == "dark" ? .dark : .light
        let period: UsagePeriod
        if CommandLine.arguments.contains("--period=month") {
            period = .month
        } else if CommandLine.arguments.contains("--period=year") {
            period = .year
        } else {
            period = .today
        }
        let view = PremiumQuotaMenuView(store: store, initialPage: page, initialPeriod: period)
            .frame(width: 420, height: height)
            .environment(\.colorScheme, scheme)
            .background(
                scheme == .dark
                    ? Color(red: 0.03, green: 0.08, blue: 0.13)
                    : Color(red: 0.94, green: 0.97, blue: 0.99)
            )
        let hostingView = NSHostingView(rootView: view)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: height)
        let renderWindow = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        renderWindow.isReleasedWhenClosed = false
        renderWindow.contentView = hostingView
        renderWindow.orderBack(nil)
        hostingView.layoutSubtreeIfNeeded()
        renderWindow.displayIfNeeded()

        // Native scroll views need a window and a layout pass before capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self, renderWindow, hostingView] in
            renderWindow.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            saveRenderedSnapshot(hostingView)
        }
    }

    private func saveRenderedSnapshot(_ hostingView: NSView) {
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            NSApp.terminate(nil)
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            NSApp.terminate(nil)
            return
        }

        let pathArgument = CommandLine.arguments.first { $0.hasPrefix("--snapshot-path=") }
        let path = pathArgument.map { String($0.dropFirst("--snapshot-path=".count)) }
            ?? "/tmp/codex-quota-offscreen.png"
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        if let reportArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--status-report-path=") }) {
            let reportPath = String(reportArgument.dropFirst("--status-report-path=".count))
            let initialTitle = statusItem.button?.title ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                let report: [String: Any] = [
                    "enabled": preference("showResetCreditCountdown", defaultValue: false),
                    "initialTitle": initialTitle,
                    "titleAfterTwoSeconds": statusItem.button?.title ?? ""
                ]
                if let reportData = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? reportData.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
                }
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.terminate(nil)
    }

    private func applyInterfaceAppearance(to view: NSView?) {
        let appearance: NSAppearance?
        switch UserDefaults.standard.string(forKey: "interfaceAppearance") ?? "system" {
        case "light": appearance = NSAppearance(named: .aqua)
        case "dark": appearance = NSAppearance(named: .darkAqua)
        default: appearance = NSApp.effectiveAppearance
        }
        popover.appearance = appearance
        view?.appearance = appearance
        view?.window?.appearance = appearance
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        if pendingStatusItemUpdate {
            updateStatusItem()
        }
    }

    private func preferredHeight(for page: QuotaMenuPage) -> CGFloat {
        switch page {
        case .overview: PanelLayoutMetrics.overviewHeight
        case .statusBarDisplay: 730
        case .customLabels: 520
        case .about: 470
        }
    }

    private var statusTitle: String {
        guard let snapshot = store.snapshot else {
            return store.isRefreshing ? "Codex 更新中…" : "Codex --"
        }
        var parts: [String] = []
        if preference("showTodayTokens"), let tokens = store.todayTokens {
            parts.append(labeledValue(displayLabel(key: "customTodayLabel", defaultValue: "今日"), compactTokens(tokens)))
        }
        if preference("showMonthTokens", defaultValue: false), let tokens = store.monthTokens {
            parts.append(labeledValue(displayLabel(key: "customMonthLabel", defaultValue: "本月"), compactTokens(tokens)))
        }
        if preference("showYearTokens", defaultValue: false), let tokens = store.yearTokens {
            parts.append(labeledValue(displayLabel(key: "customYearLabel", defaultValue: "本年"), compactTokens(tokens)))
        }
        parts += quotaOptions.compactMap { option -> String? in
            guard preference(option.preferenceKey),
                  let window = window(for: option, in: snapshot) else { return nil }
            let title = quotaDisplayLabel(option)
            if preference("showResetCountdown") {
                let reset = window.resetDate.map(relativeTime) ?? "--"
                return "\(labeledValue(title, "\(window.remainingPercent)%")) · \(reset)"
            }
            return labeledValue(title, "\(window.remainingPercent)%")
        }
        if preference("showResetCreditCountdown", defaultValue: false),
           let countdown = ResetCreditCountdownFormatter.menuBarText(
               summary: store.resetCredits,
               now: .now,
               label: displayLabel(key: "customResetCreditLabel", defaultValue: "重置卡")
           ) {
            parts.append(countdown)
        }
        let appLabel = displayLabel(key: "customAppLabel", defaultValue: "Codex")
        guard !parts.isEmpty else { return labeledValue(appLabel, "--") }
        let metrics = parts.joined(separator: " · ")
        return appLabel.isEmpty ? metrics : "\(appLabel) ｜ \(metrics)"
    }

    private var tooltip: String {
        if let error = store.errorMessage { return error }
        if case .unavailable(let message) = store.remoteSyncState {
            return "多端同步：\(message)"
        }
        let source = "Codex 限额与刷新时间 · 数据来源：\(store.dataSourceDescription)"
        return store.resetCreditAutomationMessage.map { "\(source)\n\($0)" } ?? source
    }

    private func window(for option: QuotaOption, in snapshot: RateLimitSnapshot) -> RateLimitWindow? {
        [snapshot.primary, snapshot.secondary].compactMap { $0 }.first { $0.windowDurationMins == option.minutes }
    }

    private func quotaDisplayLabel(_ option: QuotaOption) -> String {
        switch option.minutes {
        case 300: displayLabel(key: "customFiveHourLabel", defaultValue: option.shortTitle)
        case 10_080: displayLabel(key: "customWeekLabel", defaultValue: option.shortTitle)
        case 43_200: displayLabel(key: "customMonthQuotaLabel", defaultValue: option.shortTitle)
        default: option.shortTitle
        }
    }

    private func preference(_ key: String, defaultValue: Bool = true) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    private func displayLabel(key: String, defaultValue: String) -> String {
        guard preference("useCustomLabels", defaultValue: false) else { return defaultValue }
        return UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultValue
    }

    private func labeledValue(_ label: String, _ value: String) -> String {
        label.isEmpty ? value : "\(label) \(value)"
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
}

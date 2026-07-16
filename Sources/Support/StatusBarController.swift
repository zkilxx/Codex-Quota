import AppKit
import Foundation
import SwiftUI

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
        popover.contentSize = NSSize(width: 420, height: 600)

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
            Task { @MainActor in self?.render() }
        }
        render()

        if CommandLine.arguments.contains("--render-snapshot") {
            let initialPage: QuotaMenuPage
            if CommandLine.arguments.contains("--about") {
                initialPage = .about
            } else if CommandLine.arguments.contains("--edit-labels") {
                initialPage = .statusBarDisplay
            } else {
                initialPage = .overview
            }
            let delay: TimeInterval = initialPage == .overview ? 30 : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.renderSnapshot(page: initialPage)
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
        statusItem.button?.title = statusTitle
        statusItem.button?.toolTip = tooltip
        pendingStatusItemUpdate = false
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
        popover.contentSize = NSSize(width: 420, height: preferredHeight(for: initialPage))
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
        guard abs(popover.contentSize.height - height) > 0.5 else { return }
        // NSPopover owns its positioning window and natively animates contentSize
        // changes while `animates` is enabled. A single assignment preserves the
        // status-item anchor; custom frame loops cause AppKit to reposition twice.
        popover.contentSize = NSSize(width: 420, height: height)
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
            .environment(\.colorScheme, scheme)
            .background(
                scheme == .dark
                    ? Color(red: 0.03, green: 0.08, blue: 0.13)
                    : Color(red: 0.94, green: 0.97, blue: 0.99)
            )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: height)
        hostingView.layoutSubtreeIfNeeded()

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
        case .overview: 600
        case .statusBarDisplay: 570
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
        let appLabel = displayLabel(key: "customAppLabel", defaultValue: "Codex")
        guard !parts.isEmpty else { return labeledValue(appLabel, "--") }
        let metrics = parts.joined(separator: " · ")
        return appLabel.isEmpty ? metrics : "\(appLabel) ｜ \(metrics)"
    }

    private var tooltip: String {
        if let error = store.errorMessage { return error }
        return "Codex 限额与刷新时间"
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
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    private func displayLabel(key: String, defaultValue: String) -> String {
        guard preference("useCustomLabels", defaultValue: false) else { return defaultValue }
        return UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

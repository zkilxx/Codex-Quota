import AppKit

@MainActor
protocol ResetCreditConfirming {
    func confirmUse(of card: RateLimitResetCredit) async -> Bool
    func cancelPendingConfirmation()
}

@MainActor
final class ResetCreditConfirmationService: NSObject, ResetCreditConfirming, NSWindowDelegate {
    private var alert: NSAlert?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var expirationTimer: Timer?
    private var pendingCard: RateLimitResetCredit?
    private let previewOnly: Bool

    init(previewOnly: Bool = false) {
        self.previewOnly = previewOnly
        super.init()
    }

    func confirmUse(of card: RateLimitResetCredit) async -> Bool {
        guard alert == nil, card.isAvailable(at: .now), card.expirationDate != nil else { return false }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            pendingCard = card
            let alert = NSAlert()
            self.alert = alert
            alert.alertStyle = .warning
            alert.messageText = "是否使用即将到期的重置卡？"
            alert.informativeText = "这张完全重置卡将于 \(card.expirationDate!.formatted(date: .abbreviated, time: .standard)) 到期。\n确认使用后将恢复 Codex 使用额度。未确认不会消耗这张卡。"
            if previewOnly { alert.informativeText = "界面验证：这是一张测试卡，不会使用真实重置卡。\n" + alert.informativeText }
            let decline = alert.addButton(withTitle: "不使用")
            let approve = alert.addButton(withTitle: "确认使用")
            alert.layout()
            decline.target = self
            decline.action = #selector(declineUse)
            decline.keyEquivalent = "\u{1b}"
            approve.target = self
            approve.action = #selector(approveUse)
            approve.keyEquivalent = ""
            alert.window.title = "重置卡使用确认"
            alert.window.styleMask.insert(.closable)
            alert.window.delegate = self
            alert.window.level = .modalPanel
            alert.window.center()
            NSApp.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let card = self.pendingCard else { return }
                    if !card.isAvailable(at: .now) { self.finish(approved: false) }
                }
            }
            expirationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func cancelPendingConfirmation() { finish(approved: false) }

    @objc private func declineUse() { finish(approved: false) }

    @objc private func approveUse() {
        finish(approved: pendingCard?.isAvailable(at: .now) == true)
    }

    func windowWillClose(_ notification: Notification) { finish(approved: false) }

    private func finish(approved: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        expirationTimer?.invalidate()
        expirationTimer = nil
        pendingCard = nil
        alert?.window.delegate = nil
        alert?.window.orderOut(nil)
        alert?.window.close()
        alert = nil
        continuation.resume(returning: approved)
    }
}

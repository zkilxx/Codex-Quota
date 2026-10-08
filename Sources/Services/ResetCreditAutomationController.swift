import Darwin
import Foundation
import OSLog

protocol ResetCreditConsuming: Sendable {
    func read() async throws -> RateLimitResponse
    func consume(creditID: String, idempotencyKey: String) async throws -> ResetCreditConsumeOutcome
}
extension CodexResetCreditClient: ResetCreditConsuming {}

@MainActor
final class ResetCreditAutomationController {
    private let store: QuotaStore
    private let client: any ResetCreditConsuming
    private let notifier: any ResetCreditNotifying
    private let confirmer: any ResetCreditConfirming
    private let defaults: UserDefaults
    private let lockDirectory: URL?
    private let logger = Logger(subsystem: "com.local.codexquota", category: "ResetCreditAutomation")
    private let ledgerKey = "resetCreditAutomationLedger.v1"
    private var ledger = ResetCreditAutomationLedger()
    private var timer: Timer?
    private var isChecking = false
    private var lastFailureNotice: Set<String> = []

    init(store: QuotaStore, client: any ResetCreditConsuming = CodexResetCreditClient(), notifier: any ResetCreditNotifying, confirmer: any ResetCreditConfirming = ResetCreditConfirmationService(), defaults: UserDefaults = .standard, lockDirectory: URL? = nil) {
        self.store = store
        self.client = client
        self.notifier = notifier
        self.confirmer = confirmer
        self.defaults = defaults
        self.lockDirectory = lockDirectory
        reloadLedger()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        preferencesDidChange()
        Task { [weak self] in
            guard let self else { return }
            if let fresh = try? await self.client.read() { self.store.applyResetCreditSnapshot(fresh) }
            await self.evaluate()
        }
    }

    func preferencesDidChange() {
        if !enabled("autoUseExpiringResetCredits") { confirmer.cancelPendingConfirmation() }
        Task { [weak self] in
            guard let self else { return }
            if self.enabled("remindExpiringResetCredits") { await self.notifier.requestPermissionIfNeeded() }
            await self.evaluate()
        }
    }

    func notificationPermissionGranted() {
        Task { await evaluate() }
    }

    func evaluate(now: Date = .now) async {
        guard !isChecking else { return }
        guard enabled("remindExpiringResetCredits") || enabled("autoUseExpiringResetCredits") else { return }
        isChecking = true
        defer { isChecking = false }
        var descriptor = acquireLock()
        guard descriptor != nil else { return }
        defer { if let descriptor { flock(descriptor, LOCK_UN); close(descriptor) } }
        reloadLedger()
        if enabled("remindExpiringResetCredits") {
            let cards = ResetCreditAutomationPolicy.reminderCandidates(summary: store.resetCredits, now: now, alreadyReminded: ledger.remindedIDs)
            for card in cards {
                let remaining = ResetCreditCountdownFormatter.remainingText(until: card.expirationDate, now: now)
                let message = "重置卡将在 \(remaining) 后到期，请及时使用。"
                store.resetCreditAutomationMessage = message
                let delivered = await notifier.notify(identifier: "reset-credit-reminder-\(card.id)", title: "重置卡即将到期", body: message)
                if delivered {
                    ledger.markReminded(creditID: card.id)
                    _ = persistLedger()
                    logger.info("Expiration reminder delivered")
                } else {
                    store.resetCreditAutomationMessage = "\(message) 系统通知未获允许，请在系统设置中开启通知。"
                    logger.notice("Expiration reminder shown in panel; notification unavailable")
                }
            }
        }
        guard enabled("autoUseExpiringResetCredits"),
              let candidate = ResetCreditAutomationPolicy.redemptionCandidate(summary: store.resetCredits, now: now),
              ledger.attempts[candidate.id]?.completed != true else { return }
        guard ledger.approvedIDs.contains(candidate.id) || !ledger.confirmationRequestedIDs.contains(candidate.id) else { return }
        if let previous = ledger.attempts[candidate.id], now.timeIntervalSince(previous.lastAttemptAt) < 15 { return }
        do {
            var fresh = try await client.read()
            store.applyResetCreditSnapshot(fresh)
            var checkedAt = Date.now
            if ledger.attempts[candidate.id] != nil,
               fresh.rateLimitResetCredits?.credits?.contains(where: { $0.id == candidate.id && $0.status == "redeemed" }) == true {
                ledger.complete(creditID: candidate.id)
                _ = persistLedger()
                store.resetCreditAutomationMessage = "服务器已确认这张重置卡已被使用，额度状态已更新。"
                return
            }
            guard enabled("autoUseExpiringResetCredits"),
                  let card = ResetCreditAutomationPolicy.redemptionCandidate(summary: fresh.rateLimitResetCredits, now: checkedAt),
                  card.id == candidate.id else { return }
            if !ledger.approvedIDs.contains(card.id) {
                ledger.markConfirmationRequested(creditID: card.id)
                guard persistLedger() else {
                    store.resetCreditAutomationMessage = "无法保存确认记录，暂未询问或使用重置卡。"
                    return
                }
                // A person may leave the dialog unanswered; other processes must not be locked out.
                if let held = descriptor { flock(held, LOCK_UN); close(held); descriptor = nil }
                store.resetCreditAutomationMessage = "即将到期的重置卡等待你确认，未确认不会使用。"
                logger.info("Reset credit consumption awaiting user confirmation")
                let approved = await confirmer.confirmUse(of: card)
                guard approved, enabled("autoUseExpiringResetCredits") else {
                    store.resetCreditAutomationMessage = "未确认使用，这张重置卡未被消耗。"
                    logger.info("Reset credit consumption not approved")
                    return
                }
                descriptor = acquireLock()
                guard descriptor != nil else {
                    store.resetCreditAutomationMessage = "未能取得使用锁，这张重置卡暂未使用。"
                    return
                }
                reloadLedger()
                guard ledger.attempts[card.id]?.completed != true else { return }
                // Confirmation is for this card only. Read again after any time spent waiting.
                fresh = try await client.read()
                store.applyResetCreditSnapshot(fresh)
                checkedAt = Date.now
                guard enabled("autoUseExpiringResetCredits"),
                      let current = ResetCreditAutomationPolicy.redemptionCandidate(summary: fresh.rateLimitResetCredits, now: checkedAt),
                      current.id == card.id,
                      current.expiresAt == card.expiresAt else {
                    store.resetCreditAutomationMessage = "确认时这张卡已过期或不可用，未使用其他卡。"
                    return
                }
                ledger.approve(creditID: card.id)
            }
            guard ledger.approvedIDs.contains(card.id), enabled("autoUseExpiringResetCredits") else { return }
            let attempt = ledger.attempt(for: card.id, now: checkedAt)
            guard persistLedger() else {
                store.resetCreditAutomationMessage = "无法保存重置卡使用记录，暂未使用。"
                return
            }
            store.resetCreditAutomationMessage = "正在使用你已确认的重置卡…"
            logger.info("User-approved reset credit consumption started")
            let outcome = try await client.consume(creditID: card.id, idempotencyKey: attempt.idempotencyKey)
            switch outcome {
            case .reset, .alreadyRedeemed:
                ledger.complete(creditID: card.id)
                _ = persistLedger()
                store.resetCreditAutomationMessage = "你已确认的重置卡已使用，额度已重置。"
                logger.info("User-approved reset credit consumption confirmed")
                _ = await notifier.notify(identifier: "reset-credit-success-\(card.id)", title: "重置卡已使用", body: "已使用你确认的完全重置卡，使用额度已恢复。")
                if let updated = try? await client.read() { store.applyResetCreditSnapshot(updated) }
                store.recordConsumedResetCredit(id: card.id)
                store.refresh()
            case .nothingToReset:
                store.resetCreditAutomationMessage = "已确认的卡暂未使用成功：当前没有可重置的额度，将在到期前继续尝试。"
                await reportFailureOnce(cardID: card.id, message: store.resetCreditAutomationMessage!)
            case .noCredit:
                ledger.complete(creditID: card.id)
                _ = persistLedger()
                store.resetCreditAutomationMessage = "这张重置卡已不可用，未使用其他卡。"
                if let updated = try? await client.read() { store.applyResetCreditSnapshot(updated) }
            }
        } catch {
            let message = ledger.approvedIDs.contains(candidate.id)
                ? "重置卡使用结果暂未确认：\(error.localizedDescription) 到期前会沿用同一请求重试。"
                : "暂时无法核实重置卡：\(error.localizedDescription) 未使用重置卡。"
            store.resetCreditAutomationMessage = message
            logger.error("Reset credit request failed")
            await reportFailureOnce(cardID: candidate.id, message: message)
        }
    }

    private func reportFailureOnce(cardID: String, message: String) async {
        guard lastFailureNotice.insert(cardID).inserted else { return }
        _ = await notifier.notify(identifier: "reset-credit-failure-\(cardID)", title: "重置卡使用需要关注", body: message)
    }

    private func enabled(_ key: String) -> Bool { defaults.object(forKey: key) == nil || defaults.bool(forKey: key) }

    private func reloadLedger() {
        if let data = defaults.data(forKey: ledgerKey), let saved = try? JSONDecoder().decode(ResetCreditAutomationLedger.self, from: data) { ledger = saved }
    }

    private func persistLedger() -> Bool {
        guard let data = try? JSONEncoder().encode(ledger) else { return false }
        defaults.set(data, forKey: ledgerKey)
        return defaults.synchronize()
    }

    private func acquireLock() -> Int32? {
        let directory: URL
        if let lockDirectory {
            directory = lockDirectory
        } else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
            directory = support.appendingPathComponent("CodexQuota", isDirectory: true)
        }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        let descriptor = open(directory.appendingPathComponent("reset-credit-automation.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return nil }
        return descriptor
    }
}

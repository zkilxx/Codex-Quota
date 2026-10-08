import Darwin
import Foundation
import Testing
@testable import CodexQuota

private final class MemoryResetCreditDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    override func bool(forKey defaultName: String) -> Bool {
        object(forKey: defaultName) as? Bool ?? false
    }

    override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }

    override func synchronize() -> Bool { true }
}

private enum FakeResetConsumption: Sendable {
    case outcome(ResetCreditConsumeOutcome)
    case timeout
}

private actor FakeResetCreditClient: ResetCreditConsuming {
    struct Consumption: Sendable {
        let creditID: String
        let idempotencyKey: String
    }

    private var response: RateLimitResponse
    private var queuedResponses: [RateLimitResponse]
    private let marksConsumedCredits: Bool
    private var outcomes: [FakeResetConsumption]
    private var consumptions: [Consumption] = []
    private var reads = 0

    init(
        response: RateLimitResponse,
        outcomes: [FakeResetConsumption] = [.outcome(.reset)],
        responses: [RateLimitResponse] = [],
        marksConsumedCredits: Bool = false
    ) {
        self.response = response
        self.outcomes = outcomes
        self.queuedResponses = responses
        self.marksConsumedCredits = marksConsumedCredits
    }

    func read() async throws -> RateLimitResponse {
        reads += 1
        if !queuedResponses.isEmpty { response = queuedResponses.removeFirst() }
        return response
    }

    func consume(creditID: String, idempotencyKey: String) async throws -> ResetCreditConsumeOutcome {
        consumptions.append(Consumption(creditID: creditID, idempotencyKey: idempotencyKey))
        let next = outcomes.isEmpty ? .outcome(.reset) : outcomes.removeFirst()
        switch next {
        case .outcome(let outcome):
            if marksConsumedCredits && (outcome == .reset || outcome == .alreadyRedeemed),
               let cards = response.rateLimitResetCredits?.credits {
                response = try controllerTestResponse(cards.map { card in
                    guard card.id == creditID else { return card }
                    return RateLimitResetCredit(
                        id: card.id, resetType: card.resetType, status: "redeemed",
                        grantedAt: card.grantedAt, expiresAt: card.expiresAt,
                        title: card.title, description: card.description
                    )
                })
            }
            return outcome
        case .timeout: throw CodexResetCreditError.timeout
        }
    }

    func recordedConsumptions() -> [Consumption] { consumptions }
    func readCount() -> Int { reads }
}

@MainActor
private final class FakeResetCreditNotifier: ResetCreditNotifying {
    private(set) var identifiers: [String] = []

    func requestPermissionIfNeeded() async {}

    func notify(identifier: String, title: String, body: String) async -> Bool {
        identifiers.append(identifier)
        return true
    }
}

@MainActor
private final class FakeResetCreditConfirmer: ResetCreditConfirming {
    private let decision: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var requestedIDs: [String] = []
    private(set) var cancellationCount = 0
    var isPending: Bool { continuation != nil }

    init(decision: Bool? = true) { self.decision = decision }

    func confirmUse(of card: RateLimitResetCredit) async -> Bool {
        requestedIDs.append(card.id)
        if let decision { return decision }
        return await withCheckedContinuation { continuation = $0 }
    }

    func cancelPendingConfirmation() {
        cancellationCount += 1
        resolve(false)
    }

    func resolve(_ approved: Bool) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: approved)
    }
}

@MainActor
private func waitForControllerConfirmation(_ confirmer: FakeResetCreditConfirmer) async -> Bool {
    for _ in 0..<1_000 {
        if confirmer.isPending { return true }
        await Task.yield()
    }
    return false
}

private func controllerTestCanAcquireLock(_ directory: URL) -> Bool {
    let descriptor = open(directory.appendingPathComponent("reset-credit-automation.lock").path, O_RDWR)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
    flock(descriptor, LOCK_UN)
    return true
}

private func controllerTestCredit(id: String, expiresAt: Date, status: String = "available") -> RateLimitResetCredit {
    RateLimitResetCredit(
        id: id,
        resetType: "codexRateLimits",
        status: status,
        grantedAt: Int64(Date.now.timeIntervalSince1970) - 1_000,
        expiresAt: Int64(expiresAt.timeIntervalSince1970),
        title: nil,
        description: nil
    )
}

private func controllerTestResponse(_ cards: [RateLimitResetCredit]) throws -> RateLimitResponse {
    let cardsData = try JSONEncoder().encode(cards)
    let cardsJSON = String(decoding: cardsData, as: UTF8.self)
    return try JSONDecoder().decode(RateLimitResponse.self, from: Data("""
    {"rateLimits":{"limitName":"codex","planType":"plus","primary":{"usedPercent":5,"windowDurationMins":300}},
     "rateLimitResetCredits":{"availableCount":\(cards.filter { $0.status == "available" }.count),"credits":\(cardsJSON)}}
    """.utf8))
}

private func controllerTestDefaults(autoUse: Bool, remind: Bool) -> MemoryResetCreditDefaults {
    let defaults = MemoryResetCreditDefaults()
    defaults.set(autoUse as Any, forKey: "autoUseExpiringResetCredits")
    defaults.set(remind as Any, forKey: "remindExpiringResetCredits")
    return defaults
}

private func controllerTestLockDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("codex-quota-automation-test-\(UUID().uuidString)", isDirectory: true)
}

@Test @MainActor func resetCreditControllerRespectsThreeMinuteWindowAndAutoUseSwitch() async throws {
    for (remaining, autoUse) in [(240.0, true), (120.0, false)] {
        let response = try controllerTestResponse([
            controllerTestCredit(id: "card", expiresAt: .now.addingTimeInterval(remaining))
        ])
        let store = QuotaStore(startServices: false)
        store.applyResetCreditSnapshot(response)
        let client = FakeResetCreditClient(response: response)
        let controller = ResetCreditAutomationController(
            store: store,
            client: client,
            notifier: FakeResetCreditNotifier(),
            confirmer: FakeResetCreditConfirmer(),
            defaults: controllerTestDefaults(autoUse: autoUse, remind: false),
            lockDirectory: controllerTestLockDirectory()
        )

        await controller.evaluate()

        let calls = await client.recordedConsumptions()
        let reads = await client.readCount()
        #expect(calls.isEmpty)
        #expect(reads == 0)
    }
}

@Test @MainActor func resetCreditControllerRechecksTheTargetCardWithoutSwitchingCards() async throws {
    let now = Date.now
    let target = controllerTestCredit(id: "target", expiresAt: now.addingTimeInterval(120))
    let other = controllerTestCredit(id: "other", expiresAt: now.addingTimeInterval(150))
    let initial = try controllerTestResponse([target, other])
    let fresh = try controllerTestResponse([
        controllerTestCredit(id: "target", expiresAt: now.addingTimeInterval(120), status: "redeemed"), other
    ])
    let store = QuotaStore(startServices: false)
    store.applyResetCreditSnapshot(initial)
    let client = FakeResetCreditClient(response: fresh)
    let controller = ResetCreditAutomationController(
        store: store,
        client: client,
        notifier: FakeResetCreditNotifier(),
        confirmer: FakeResetCreditConfirmer(),
        defaults: controllerTestDefaults(autoUse: true, remind: false),
        lockDirectory: controllerTestLockDirectory()
    )

    await controller.evaluate(now: now)

    let calls = await client.recordedConsumptions()
    let reads = await client.readCount()
    #expect(calls.isEmpty)
    #expect(reads == 1)
    #expect(store.resetCredits?.credits?.first(where: { $0.id == "target" })?.status == "redeemed")
}

@Test @MainActor func resetCreditControllerPersistsSuccessAndDoesNotUseTheSameCardAgain() async throws {
    let response = try controllerTestResponse([
        controllerTestCredit(id: "card", expiresAt: .now.addingTimeInterval(120))
    ])
    let store = QuotaStore(startServices: false)
    store.applyResetCreditSnapshot(response)
    let defaults = controllerTestDefaults(autoUse: true, remind: false)
    let client = FakeResetCreditClient(response: response)
    let notifier = FakeResetCreditNotifier()
    let directory = controllerTestLockDirectory()
    let controller = ResetCreditAutomationController(
        store: store, client: client, notifier: notifier, confirmer: FakeResetCreditConfirmer(),
        defaults: defaults, lockDirectory: directory
    )

    await controller.evaluate()

    let restored = ResetCreditAutomationController(
        store: store, client: client, notifier: notifier, confirmer: FakeResetCreditConfirmer(),
        defaults: defaults, lockDirectory: directory
    )
    await restored.evaluate(now: .now.addingTimeInterval(30))

    let calls = await client.recordedConsumptions()
    #expect(calls.count == 1)
    #expect(calls.first?.creditID == "card")
    #expect(notifier.identifiers.filter { $0 == "reset-credit-success-card" }.count == 1)
}

@Test @MainActor func resetCreditControllerRetriesWithTheSameKeyAndHonorsCooldown() async throws {
    for failure in [FakeResetConsumption.outcome(.nothingToReset), .timeout] {
        let now = Date.now
        let response = try controllerTestResponse([
            controllerTestCredit(id: "card", expiresAt: now.addingTimeInterval(120))
        ])
        let store = QuotaStore(startServices: false)
        store.applyResetCreditSnapshot(response)
        let client = FakeResetCreditClient(response: response, outcomes: [failure, .outcome(.reset)])
        let confirmer = FakeResetCreditConfirmer()
        let controller = ResetCreditAutomationController(
            store: store,
            client: client,
            notifier: FakeResetCreditNotifier(),
            confirmer: confirmer,
            defaults: controllerTestDefaults(autoUse: true, remind: false),
            lockDirectory: controllerTestLockDirectory()
        )

        await controller.evaluate(now: now)
        await controller.evaluate(now: now.addingTimeInterval(1))
        let cooledDownCalls = await client.recordedConsumptions()
        #expect(cooledDownCalls.count == 1)

        await controller.evaluate(now: .now.addingTimeInterval(16))
        let calls = await client.recordedConsumptions()
        #expect(calls.count == 2)
        #expect(calls.first?.creditID == "card")
        #expect(calls.last?.creditID == "card")
        #expect(calls.first?.idempotencyKey == calls.last?.idempotencyKey)
        #expect(confirmer.requestedIDs == ["card"])
    }
}

@Test @MainActor func resetCreditControllerDeliversTenMinuteReminderOnlyOnceAcrossRestart() async throws {
    let now = Date.now
    let response = try controllerTestResponse([
        controllerTestCredit(id: "card", expiresAt: now.addingTimeInterval(500))
    ])
    let store = QuotaStore(startServices: false)
    store.applyResetCreditSnapshot(response)
    let client = FakeResetCreditClient(response: response)
    let notifier = FakeResetCreditNotifier()
    let defaults = controllerTestDefaults(autoUse: false, remind: true)
    let directory = controllerTestLockDirectory()
    let controller = ResetCreditAutomationController(
        store: store, client: client, notifier: notifier, confirmer: FakeResetCreditConfirmer(),
        defaults: defaults, lockDirectory: directory
    )

    await controller.evaluate(now: now)
    await controller.evaluate(now: now.addingTimeInterval(1))
    let restored = ResetCreditAutomationController(
        store: store, client: client, notifier: notifier, confirmer: FakeResetCreditConfirmer(),
        defaults: defaults, lockDirectory: directory
    )
    await restored.evaluate(now: now.addingTimeInterval(2))

    #expect(notifier.identifiers == ["reset-credit-reminder-card"])
    let calls = await client.recordedConsumptions()
    #expect(calls.isEmpty)
}

@Test @MainActor func resetCreditControllerPersistsDeclineWithoutConsumingOrAskingAgain() async throws {
    let now = Date.now
    let response = try controllerTestResponse([
        controllerTestCredit(id: "declined", expiresAt: now.addingTimeInterval(120))
    ])
    let store = QuotaStore(startServices: false)
    store.applyResetCreditSnapshot(response)
    let client = FakeResetCreditClient(response: response)
    let confirmer = FakeResetCreditConfirmer(decision: false)
    let defaults = controllerTestDefaults(autoUse: true, remind: false)
    let directory = controllerTestLockDirectory()
    let controller = ResetCreditAutomationController(
        store: store, client: client, notifier: FakeResetCreditNotifier(), confirmer: confirmer,
        defaults: defaults, lockDirectory: directory
    )

    await controller.evaluate(now: now)
    await controller.evaluate(now: now.addingTimeInterval(20))
    let restored = ResetCreditAutomationController(
        store: store, client: client, notifier: FakeResetCreditNotifier(), confirmer: confirmer,
        defaults: defaults, lockDirectory: directory
    )
    await restored.evaluate(now: now.addingTimeInterval(40))

    #expect(confirmer.requestedIDs == ["declined"])
    let calls = await client.recordedConsumptions()
    #expect(calls.isEmpty)
}

@Test @MainActor func resetCreditControllerWaitsForApprovalWithoutConsumingOrHoldingFileLock() async throws {
    let response = try controllerTestResponse([
        controllerTestCredit(id: "pending", expiresAt: .now.addingTimeInterval(120))
    ])
    let store = QuotaStore(startServices: false)
    store.applyResetCreditSnapshot(response)
    let client = FakeResetCreditClient(response: response)
    let confirmer = FakeResetCreditConfirmer(decision: nil)
    let directory = controllerTestLockDirectory()
    let controller = ResetCreditAutomationController(
        store: store, client: client, notifier: FakeResetCreditNotifier(), confirmer: confirmer,
        defaults: controllerTestDefaults(autoUse: true, remind: false), lockDirectory: directory
    )
    let evaluation = Task { await controller.evaluate() }
    defer {
        confirmer.resolve(false)
        evaluation.cancel()
    }
    let isPending = await waitForControllerConfirmation(confirmer)
    try #require(isPending)

    let pendingCalls = await client.recordedConsumptions()
    #expect(pendingCalls.isEmpty)
    #expect(controllerTestCanAcquireLock(directory))
    await controller.evaluate()
    #expect(confirmer.requestedIDs == ["pending"])

    confirmer.resolve(true)
    await evaluation.value
    let approvedCalls = await client.recordedConsumptions()
    #expect(approvedCalls.count == 1)
    #expect(approvedCalls.first?.creditID == "pending")
}

@Test @MainActor func resetCreditControllerRevalidatesApprovedCardWithoutReplacingIt() async throws {
    for staleState in ["expired", "redeemed", "missing"] {
        let now = Date.now
        let target = controllerTestCredit(id: "target", expiresAt: now.addingTimeInterval(120))
        let other = controllerTestCredit(id: "other", expiresAt: now.addingTimeInterval(150))
        let initial = try controllerTestResponse([target, other])
        let staleCards = staleState == "missing" ? [other] : [
            controllerTestCredit(
                id: "target",
                expiresAt: staleState == "expired" ? now.addingTimeInterval(-1) : now.addingTimeInterval(120),
                status: staleState == "redeemed" ? "redeemed" : "available"
            ), other
        ]
        let stale = try controllerTestResponse(staleCards)
        let store = QuotaStore(startServices: false)
        store.applyResetCreditSnapshot(initial)
        let client = FakeResetCreditClient(response: stale, responses: [initial, stale])
        let confirmer = FakeResetCreditConfirmer()
        let controller = ResetCreditAutomationController(
            store: store, client: client, notifier: FakeResetCreditNotifier(), confirmer: confirmer,
            defaults: controllerTestDefaults(autoUse: true, remind: false),
            lockDirectory: controllerTestLockDirectory()
        )

        await controller.evaluate(now: now)

        #expect(confirmer.requestedIDs == ["target"])
        let calls = await client.recordedConsumptions()
        #expect(calls.isEmpty)
        let reads = await client.readCount()
        #expect(reads == 2)
    }
}

@Test @MainActor func resetCreditControllerHonorsAutoUseBeingDisabledDuringConfirmation() async throws {
    let response = try controllerTestResponse([
        controllerTestCredit(id: "pending", expiresAt: .now.addingTimeInterval(120))
    ])
    let store = QuotaStore(startServices: false)
    store.applyResetCreditSnapshot(response)
    let client = FakeResetCreditClient(response: response)
    let confirmer = FakeResetCreditConfirmer(decision: nil)
    let defaults = controllerTestDefaults(autoUse: true, remind: false)
    let controller = ResetCreditAutomationController(
        store: store, client: client, notifier: FakeResetCreditNotifier(), confirmer: confirmer,
        defaults: defaults, lockDirectory: controllerTestLockDirectory()
    )
    let evaluation = Task { await controller.evaluate() }
    defer {
        confirmer.resolve(false)
        evaluation.cancel()
    }
    let isPending = await waitForControllerConfirmation(confirmer)
    try #require(isPending)

    defaults.set(false, forKey: "autoUseExpiringResetCredits")
    controller.preferencesDidChange()
    confirmer.resolve(true)
    await evaluation.value

    let calls = await client.recordedConsumptions()
    #expect(calls.isEmpty)
}

@Test @MainActor func resetCreditControllerDoesNotTreatLegacyPendingAttemptAsApproval() async throws {
    let now = Date.now
    let response = try controllerTestResponse([
        controllerTestCredit(id: "legacy", expiresAt: now.addingTimeInterval(120))
    ])
    let defaults = controllerTestDefaults(autoUse: true, remind: false)
    let legacyData = try JSONSerialization.data(withJSONObject: [
        "remindedIDs": [],
        "attempts": ["legacy": [
            "idempotencyKey": "legacy-attempt-key",
            "lastAttemptAt": now.addingTimeInterval(-30).timeIntervalSinceReferenceDate,
            "completed": false
        ]]
    ])
    defaults.set(legacyData, forKey: "resetCreditAutomationLedger.v1")
    let store = QuotaStore(startServices: false)
    store.applyResetCreditSnapshot(response)
    let client = FakeResetCreditClient(response: response)
    let confirmer = FakeResetCreditConfirmer(decision: false)
    let controller = ResetCreditAutomationController(
        store: store, client: client, notifier: FakeResetCreditNotifier(), confirmer: confirmer,
        defaults: defaults, lockDirectory: controllerTestLockDirectory()
    )

    await controller.evaluate(now: now)

    #expect(confirmer.requestedIDs == ["legacy"])
    let calls = await client.recordedConsumptions()
    #expect(calls.isEmpty)
    let saved = try #require(defaults.data(forKey: "resetCreditAutomationLedger.v1"))
    let ledger = try JSONDecoder().decode(ResetCreditAutomationLedger.self, from: saved)
    #expect(ledger.attempts["legacy"]?.idempotencyKey == "legacy-attempt-key")
}

@Test @MainActor func resetCreditControllerPersistsApprovalForRetriesAndAsksForEachNewCard() async throws {
    let now = Date.now
    let response = try controllerTestResponse([
        controllerTestCredit(id: "first", expiresAt: now.addingTimeInterval(120)),
        controllerTestCredit(id: "second", expiresAt: now.addingTimeInterval(150))
    ])
    let store = QuotaStore(startServices: false)
    store.applyResetCreditSnapshot(response)
    let client = FakeResetCreditClient(
        response: response,
        outcomes: [.timeout, .outcome(.reset), .outcome(.reset)],
        marksConsumedCredits: true
    )
    let confirmer = FakeResetCreditConfirmer()
    let defaults = controllerTestDefaults(autoUse: true, remind: false)
    let directory = controllerTestLockDirectory()
    let controller = ResetCreditAutomationController(
        store: store, client: client, notifier: FakeResetCreditNotifier(), confirmer: confirmer,
        defaults: defaults, lockDirectory: directory
    )

    await controller.evaluate(now: now)
    let restored = ResetCreditAutomationController(
        store: store, client: client, notifier: FakeResetCreditNotifier(), confirmer: confirmer,
        defaults: defaults, lockDirectory: directory
    )
    await restored.evaluate(now: now.addingTimeInterval(16))
    await restored.evaluate(now: now.addingTimeInterval(32))

    let calls = await client.recordedConsumptions()
    #expect(calls.map(\.creditID) == ["first", "first", "second"])
    #expect(calls[0].idempotencyKey == calls[1].idempotencyKey)
    #expect(calls[1].idempotencyKey != calls[2].idempotencyKey)
    #expect(confirmer.requestedIDs == ["first", "second"])
}

import Foundation
import Testing
@testable import CodexQuota

@Test func resetCreditAttemptsReuseTheirIdempotencyKeyAfterRestart() throws {
    var ledger = ResetCreditAutomationLedger()
    let first = ledger.attempt(for: "credit-1", now: Date(timeIntervalSince1970: 1_000))
    let encoded = try JSONEncoder().encode(ledger)
    var restored = try JSONDecoder().decode(ResetCreditAutomationLedger.self, from: encoded)
    let retried = restored.attempt(for: "credit-1", now: Date(timeIntervalSince1970: 1_060))

    #expect(UUID(uuidString: first.idempotencyKey) != nil)
    #expect(retried.idempotencyKey == first.idempotencyKey)
    #expect(retried.lastAttemptAt == Date(timeIntervalSince1970: 1_060))
    #expect(!retried.completed)
    #expect(restored.attempts["credit-1"]?.lastAttemptAt == retried.lastAttemptAt)
}

@Test func resetCreditAttemptsUseDifferentIdempotencyKeysForDifferentCards() {
    var ledger = ResetCreditAutomationLedger()
    let now = Date(timeIntervalSince1970: 1_000)
    let first = ledger.attempt(for: "credit-1", now: now)
    let second = ledger.attempt(for: "credit-2", now: now)

    #expect(first.idempotencyKey != second.idempotencyKey)
    #expect(UUID(uuidString: second.idempotencyKey) != nil)
}

@Test func resetCreditCompletedAttemptsRemainCompletedAcrossRestartAndRetry() throws {
    var ledger = ResetCreditAutomationLedger()
    let first = ledger.attempt(for: "credit-1", now: Date(timeIntervalSince1970: 1_000))
    ledger.complete(creditID: "credit-1")
    let encoded = try JSONEncoder().encode(ledger)
    var restored = try JSONDecoder().decode(ResetCreditAutomationLedger.self, from: encoded)

    #expect(restored.attempts["credit-1"]?.completed == true)

    let retried = restored.attempt(for: "credit-1", now: Date(timeIntervalSince1970: 1_060))
    #expect(retried.completed)
    #expect(retried.idempotencyKey == first.idempotencyKey)
}

@Test func resetCreditRemindersStayRecordedAcrossRestart() throws {
    var ledger = ResetCreditAutomationLedger()
    ledger.markReminded(creditID: "credit-1")
    ledger.markReminded(creditID: "credit-1")
    ledger.markReminded(creditID: "credit-2")
    let encoded = try JSONEncoder().encode(ledger)
    let restored = try JSONDecoder().decode(ResetCreditAutomationLedger.self, from: encoded)

    #expect(restored.remindedIDs == ["credit-1", "credit-2"])
}

@Test func resetCreditLegacyAttemptsDoNotCountAsUserApproval() throws {
    let legacy = Data("""
    {
      "remindedIDs": ["pending"],
      "attempts": {
        "pending": {"idempotencyKey":"legacy-pending-key","lastAttemptAt":321,"completed":false},
        "done": {"idempotencyKey":"legacy-done-key","lastAttemptAt":300,"completed":true}
      }
    }
    """.utf8)

    let restored = try JSONDecoder().decode(ResetCreditAutomationLedger.self, from: legacy)

    #expect(restored.remindedIDs == ["pending"])
    #expect(restored.attempts["pending"]?.idempotencyKey == "legacy-pending-key")
    #expect(restored.attempts["pending"]?.lastAttemptAt == Date(timeIntervalSinceReferenceDate: 321))
    #expect(restored.attempts["done"]?.completed == true)
    #expect(restored.confirmationRequestedIDs.isEmpty)
    #expect(restored.approvedIDs.isEmpty)
}

@Test func resetCreditConfirmationRequestsAndApprovalsPersistAcrossRestart() throws {
    var ledger = ResetCreditAutomationLedger()
    ledger.markConfirmationRequested(creditID: "requested")
    ledger.approve(creditID: "approved")

    let encoded = try JSONEncoder().encode(ledger)
    let restored = try JSONDecoder().decode(ResetCreditAutomationLedger.self, from: encoded)

    #expect(restored.confirmationRequestedIDs == ["requested", "approved"])
    #expect(restored.approvedIDs == ["approved"])
}

@Test func resetCreditApprovalOnlyAuthorizesThatSpecificCard() {
    var ledger = ResetCreditAutomationLedger()
    ledger.approve(creditID: "approved")
    ledger.markConfirmationRequested(creditID: "declined")
    _ = ledger.attempt(for: "oldAttempt", now: .now)

    #expect(ledger.approvedIDs.contains("approved"))
    #expect(!ledger.approvedIDs.contains("declined"))
    #expect(!ledger.approvedIDs.contains("oldAttempt"))
    #expect(!ledger.approvedIDs.contains("unrelated"))
    #expect(ledger.confirmationRequestedIDs.contains("approved"))
}

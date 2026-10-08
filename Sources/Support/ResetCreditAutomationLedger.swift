import Foundation

struct ResetCreditAutomationLedger: Codable, Sendable {
    struct Attempt: Codable, Sendable {
        let idempotencyKey: String
        var lastAttemptAt: Date
        var completed: Bool
    }

    var remindedIDs: Set<String> = []
    var attempts: [String: Attempt] = [:]
    var confirmationRequestedIDs: Set<String> = []
    var approvedIDs: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case remindedIDs, attempts, confirmationRequestedIDs, approvedIDs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        remindedIDs = try values.decode(Set<String>.self, forKey: .remindedIDs)
        attempts = try values.decode([String: Attempt].self, forKey: .attempts)
        confirmationRequestedIDs = try values.decodeIfPresent(Set<String>.self, forKey: .confirmationRequestedIDs) ?? []
        approvedIDs = try values.decodeIfPresent(Set<String>.self, forKey: .approvedIDs) ?? []
    }

    mutating func attempt(for creditID: String, now: Date) -> Attempt {
        var record = attempts[creditID] ?? Attempt(
            idempotencyKey: UUID().uuidString,
            lastAttemptAt: now,
            completed: false
        )
        record.lastAttemptAt = now
        attempts[creditID] = record
        return record
    }

    mutating func complete(creditID: String) {
        guard var record = attempts[creditID] else { return }
        record.completed = true
        attempts[creditID] = record
    }

    mutating func markReminded(creditID: String) {
        remindedIDs.insert(creditID)
    }

    mutating func markConfirmationRequested(creditID: String) {
        confirmationRequestedIDs.insert(creditID)
    }

    mutating func approve(creditID: String) {
        confirmationRequestedIDs.insert(creditID)
        approvedIDs.insert(creditID)
    }
}

import Foundation

enum ResetCreditAutomationPolicy {
    static func reminderCandidates(
        summary: RateLimitResetCreditsSummary?,
        now: Date,
        alreadyReminded: Set<String>
    ) -> [RateLimitResetCredit] {
        var seenIDs = alreadyReminded
        return expiringCredits(summary: summary, now: now, within: 600).filter {
            seenIDs.insert($0.id).inserted
        }
    }

    static func redemptionCandidate(
        summary: RateLimitResetCreditsSummary?,
        now: Date
    ) -> RateLimitResetCredit? {
        expiringCredits(summary: summary, now: now, within: 180).first
    }

    private static func expiringCredits(
        summary: RateLimitResetCreditsSummary?,
        now: Date,
        within seconds: TimeInterval
    ) -> [RateLimitResetCredit] {
        (summary?.availableFullResetCredits(at: now) ?? []).filter { credit in
            guard let expirationDate = credit.expirationDate else { return false }
            let remaining = expirationDate.timeIntervalSince(now)
            return remaining > 0 && remaining <= seconds
        }
    }
}

import Foundation
import Testing
@testable import CodexQuota

private let automationNow = Date(timeIntervalSince1970: 1_000)

private func automationCredit(
    id: String,
    remaining: Int64?,
    status: String = "available",
    resetType: String = "codexRateLimits"
) -> RateLimitResetCredit {
    RateLimitResetCredit(
        id: id,
        resetType: resetType,
        status: status,
        grantedAt: 500,
        expiresAt: remaining.map { 1_000 + $0 },
        title: nil,
        description: nil
    )
}

private func automationSummary(_ credits: [RateLimitResetCredit]) -> RateLimitResetCreditsSummary {
    RateLimitResetCreditsSummary(availableCount: Int64(credits.count), credits: credits)
}

@Test func resetCreditReminderIncludesTenMinuteBoundaryAndExcludesExpiredCards() {
    let summary = automationSummary([
        automationCredit(id: "early", remaining: 601),
        automationCredit(id: "boundary", remaining: 600),
        automationCredit(id: "lastSecond", remaining: 1),
        automationCredit(id: "expiredNow", remaining: 0),
        automationCredit(id: "expired", remaining: -1)
    ])

    let candidates = ResetCreditAutomationPolicy.reminderCandidates(
        summary: summary, now: automationNow, alreadyReminded: []
    )

    #expect(candidates.map(\.id) == ["lastSecond", "boundary"])
}

@Test func resetCreditReminderIgnoresUsedOtherTypeAndNonexpiringCards() {
    let summary = automationSummary([
        automationCredit(id: "redeemed", remaining: 60, status: "redeemed"),
        automationCredit(id: "redeeming", remaining: 60, status: "redeeming"),
        automationCredit(id: "unknownStatus", remaining: 60, status: "futureStatus"),
        automationCredit(id: "otherType", remaining: 60, resetType: "futureType"),
        automationCredit(id: "nonexpiring", remaining: nil),
        automationCredit(id: "usable", remaining: 60)
    ])

    let candidates = ResetCreditAutomationPolicy.reminderCandidates(
        summary: summary, now: automationNow, alreadyReminded: []
    )

    #expect(candidates.map(\.id) == ["usable"])
}

@Test func resetCreditRemindersAreSortedAndDoNotRepeatAnAlreadyRemindedCard() {
    let summary = automationSummary([
        automationCredit(id: "later", remaining: 500),
        automationCredit(id: "reminded", remaining: 10),
        automationCredit(id: "earlier", remaining: 200),
        automationCredit(id: "earlier", remaining: 200)
    ])

    let candidates = ResetCreditAutomationPolicy.reminderCandidates(
        summary: summary, now: automationNow, alreadyReminded: ["reminded"]
    )

    #expect(candidates.map(\.id) == ["earlier", "later"])
}

@Test func resetCreditReminderRequiresExpiryDetails() {
    let summaries: [RateLimitResetCreditsSummary?] = [
        nil,
        .init(availableCount: 4, credits: nil),
        .init(availableCount: 0, credits: [])
    ]
    for summary in summaries {
        #expect(ResetCreditAutomationPolicy.reminderCandidates(
            summary: summary, now: automationNow, alreadyReminded: []
        ).isEmpty)
        #expect(ResetCreditAutomationPolicy.redemptionCandidate(summary: summary, now: automationNow) == nil)
    }
}

@Test func resetCreditRedemptionIncludesThreeMinuteBoundary() {
    let boundary = automationCredit(id: "boundary", remaining: 180)
    #expect(ResetCreditAutomationPolicy.redemptionCandidate(
        summary: automationSummary([boundary]), now: automationNow
    )?.id == "boundary")
    #expect(ResetCreditAutomationPolicy.redemptionCandidate(
        summary: automationSummary([automationCredit(id: "tooEarly", remaining: 181)]), now: automationNow
    ) == nil)
}

@Test func resetCreditRedemptionChoosesSoonestUsableCardAndStopsAtExpiry() {
    let summary = automationSummary([
        automationCredit(id: "later", remaining: 180),
        automationCredit(id: "earliest", remaining: 1),
        automationCredit(id: "expiredNow", remaining: 0),
        automationCredit(id: "expired", remaining: -1),
        automationCredit(id: "redeemed", remaining: 1, status: "redeemed"),
        automationCredit(id: "otherType", remaining: 1, resetType: "futureType"),
        automationCredit(id: "nonexpiring", remaining: nil)
    ])

    #expect(ResetCreditAutomationPolicy.redemptionCandidate(summary: summary, now: automationNow)?.id == "earliest")
    #expect(ResetCreditAutomationPolicy.redemptionCandidate(
        summary: summary, now: automationNow.addingTimeInterval(1)
    )?.id == "later")
    #expect(ResetCreditAutomationPolicy.redemptionCandidate(
        summary: summary, now: automationNow.addingTimeInterval(180)
    ) == nil)
}

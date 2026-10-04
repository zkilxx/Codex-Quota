import Foundation
import Testing
@testable import CodexQuota

private func menuBarResetCredit(
    id: String,
    expiresAt: Int64?,
    status: String = "available"
) -> RateLimitResetCredit {
    RateLimitResetCredit(
        id: id,
        resetType: "codexRateLimits",
        status: status,
        grantedAt: 500,
        expiresAt: expiresAt,
        title: nil,
        description: nil
    )
}

@Test func menuBarResetCreditCountdownUsesEarliestAvailableExpiration() {
    let summary = RateLimitResetCreditsSummary(availableCount: 2, credits: [
        menuBarResetCredit(id: "later", expiresAt: 4_000),
        menuBarResetCredit(id: "earlier", expiresAt: 1_100)
    ])

    #expect(ResetCreditCountdownFormatter.menuBarText(
        summary: summary,
        now: Date(timeIntervalSince1970: 1_000)
    ) == "重置卡 00:01:40")
}

@Test func menuBarResetCreditCountdownIgnoresExpiredAndRedeemedCards() {
    let summary = RateLimitResetCreditsSummary(availableCount: 2, credits: [
        menuBarResetCredit(id: "expired", expiresAt: 999),
        menuBarResetCredit(id: "redeemed", expiresAt: 1_001, status: "redeemed"),
        menuBarResetCredit(id: "usable", expiresAt: 1_060)
    ])

    #expect(ResetCreditCountdownFormatter.menuBarText(
        summary: summary,
        now: Date(timeIntervalSince1970: 1_000)
    ) == "重置卡 00:01:00")
}

@Test func menuBarResetCreditCountdownSwitchesCardsAtExactExpirationBoundary() {
    let summary = RateLimitResetCreditsSummary(availableCount: 2, credits: [
        menuBarResetCredit(id: "first", expiresAt: 1_001),
        menuBarResetCredit(id: "second", expiresAt: 1_061)
    ])

    #expect(ResetCreditCountdownFormatter.menuBarText(
        summary: summary,
        now: Date(timeIntervalSince1970: 1_000)
    ) == "重置卡 00:00:01")
    #expect(ResetCreditCountdownFormatter.menuBarText(
        summary: summary,
        now: Date(timeIntervalSince1970: 1_001)
    ) == "重置卡 00:01:00")
    #expect(ResetCreditCountdownFormatter.menuBarText(
        summary: summary,
        now: Date(timeIntervalSince1970: 1_061)
    ) == nil)
}

@Test func menuBarResetCreditCountdownRequiresUsableCardDetails() {
    let summaries: [RateLimitResetCreditsSummary?] = [
        nil,
        .init(availableCount: 4, credits: nil),
        .init(availableCount: 0, credits: []),
        .init(availableCount: 1, credits: [menuBarResetCredit(id: "expired", expiresAt: 1_000)])
    ]

    for summary in summaries {
        #expect(ResetCreditCountdownFormatter.menuBarText(
            summary: summary,
            now: Date(timeIntervalSince1970: 1_000)
        ) == nil)
    }
}

@Test func menuBarResetCreditCountdownPreservesNonexpiringCardFormat() {
    let summary = RateLimitResetCreditsSummary(availableCount: 1, credits: [
        menuBarResetCredit(id: "nonexpiring", expiresAt: nil)
    ])

    #expect(ResetCreditCountdownFormatter.menuBarText(
        summary: summary,
        now: Date(timeIntervalSince1970: 1_000)
    ) == "重置卡 长期有效")
}

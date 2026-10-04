import Foundation
import Testing
@testable import CodexQuota

private func resetCredit(
    id: String,
    expiresAt: Int64? = 2_000,
    status: String = "available",
    resetType: String = "codexRateLimits"
) -> RateLimitResetCredit {
    RateLimitResetCredit(
        id: id,
        resetType: resetType,
        status: status,
        grantedAt: 500,
        expiresAt: expiresAt,
        title: "Full reset",
        description: nil
    )
}

@Test func resetCreditsDecodeFromAccountRateLimitsResponse() throws {
    let data = Data("""
    {
      "rateLimits": {"planType": "pro"},
      "rateLimitResetCredits": {
        "availableCount": 4,
        "credits": [
          {"id":"mock-1","resetType":"codexRateLimits","status":"available","grantedAt":1790956800,"expiresAt":1791129600,"title":"Full reset","description":null},
          {"id":"mock-2","resetType":"codexRateLimits","status":"available","grantedAt":1790956800,"expiresAt":1791216000,"title":"Full reset"},
          {"id":"mock-3","resetType":"codexRateLimits","status":"available","grantedAt":1790956800,"expiresAt":1792771200},
          {"id":"mock-4","resetType":"codexRateLimits","status":"available","grantedAt":1790956800,"expiresAt":1793376000}
        ]
      }
    }
    """.utf8)

    let response = try JSONDecoder().decode(RateLimitResponse.self, from: data)
    let summary = try #require(response.rateLimitResetCredits)
    let credit = try #require(summary.credits?.first)
    #expect(summary.availableCount == 4)
    #expect(summary.credits?.count == 4)
    #expect(credit.isFullReset)
    #expect(credit.title == "Full reset")
    #expect(credit.expirationDate == Date(timeIntervalSince1970: 1_791_129_600))
    #expect(response.preferredSnapshot.planType == "pro")
}

@Test(arguments: [
    "{\"rateLimits\":{}}",
    "{\"rateLimits\":{},\"rateLimitResetCredits\":null}"
])
func legacyOrNullResetCreditSummaryRemainsUnavailable(json: String) throws {
    let response = try JSONDecoder().decode(RateLimitResponse.self, from: Data(json.utf8))
    #expect(response.rateLimitResetCredits == nil)
}

@Test(arguments: [
    "{\"availableCount\":4}",
    "{\"availableCount\":4,\"credits\":null}"
])
func countOnlyResetCreditSummaryPreservesServerCount(json: String) throws {
    let summary = try JSONDecoder().decode(RateLimitResetCreditsSummary.self, from: Data(json.utf8))
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(summary.credits == nil)
    #expect(summary.availableFullResetCredits(at: now).isEmpty)
    #expect(summary.effectiveAvailableCount(at: now) == 4)
}

@Test func fetchedEmptyCreditDetailsRemainDistinctFromUnavailableDetails() throws {
    let summary = try JSONDecoder().decode(
        RateLimitResetCreditsSummary.self,
        from: Data("{\"availableCount\":0,\"credits\":[]}".utf8)
    )
    #expect(summary.credits == [])
    #expect(summary.effectiveAvailableCount(at: Date(timeIntervalSince1970: 1_000)) == 0)
}

@Test(arguments: [
    "{\"id\":\"mock\",\"resetType\":\"codexRateLimits\",\"status\":\"available\",\"grantedAt\":500}",
    "{\"id\":\"mock\",\"resetType\":\"codexRateLimits\",\"status\":\"available\",\"grantedAt\":500,\"expiresAt\":null}"
])
func creditsWithoutExpirationDecodeAndRemainAvailable(json: String) throws {
    let credit = try JSONDecoder().decode(RateLimitResetCredit.self, from: Data(json.utf8))
    #expect(credit.expirationDate == nil)
    #expect(credit.isAvailable(at: Date(timeIntervalSince1970: 10_000)))
    #expect(credit.title == nil)
    #expect(credit.description == nil)
}

@Test func futureResetCreditStringsDoNotBreakResponseDecoding() throws {
    let data = Data("""
    {"id":"mock-future","resetType":"futureResetType","status":"futureStatus","grantedAt":500,"expiresAt":2000}
    """.utf8)
    let credit = try JSONDecoder().decode(RateLimitResetCredit.self, from: data)
    #expect(credit.resetType == "futureResetType")
    #expect(credit.status == "futureStatus")
    #expect(!credit.isFullReset)
    #expect(!credit.isAvailable(at: Date(timeIntervalSince1970: 1_000)))
}

@Test func availableFullResetCreditsExcludeExpiredAndNonavailableRows() {
    let summary = RateLimitResetCreditsSummary(availableCount: 4, credits: [
        resetCredit(id: "future", expiresAt: 1_001),
        resetCredit(id: "boundary", expiresAt: 1_000),
        resetCredit(id: "expired", expiresAt: 999),
        resetCredit(id: "redeeming", status: "redeeming"),
        resetCredit(id: "redeemed", status: "redeemed"),
        resetCredit(id: "unknown", status: "unknown"),
        resetCredit(id: "other-type", resetType: "unknown"),
        resetCredit(id: "no-expiration", expiresAt: nil)
    ])

    let available = summary.availableFullResetCredits(at: Date(timeIntervalSince1970: 1_000))
    #expect(available.map(\.id) == ["future", "no-expiration"])
    #expect(summary.effectiveAvailableCount(at: Date(timeIntervalSince1970: 1_000)) == 2)
}

@Test func resetCreditSortingUsesEarliestExpirationThenIDWithNoExpirationLast() {
    let summary = RateLimitResetCreditsSummary(availableCount: 5, credits: [
        resetCredit(id: "unlimited-z", expiresAt: nil),
        resetCredit(id: "later", expiresAt: 3_000),
        resetCredit(id: "early-b", expiresAt: 2_000),
        resetCredit(id: "unlimited-a", expiresAt: nil),
        resetCredit(id: "early-a", expiresAt: 2_000)
    ])

    #expect(summary.availableFullResetCredits(at: Date(timeIntervalSince1970: 1_000)).map(\.id) == [
        "early-a", "early-b", "later", "unlimited-a", "unlimited-z"
    ])
}

@Test func cappedDetailsOnlySubtractKnownExpiredAvailableCredits() {
    let summary = RateLimitResetCreditsSummary(availableCount: 4, credits: [
        resetCredit(id: "expired", expiresAt: 1_000),
        resetCredit(id: "active", expiresAt: 2_000),
        resetCredit(id: "already-redeemed", expiresAt: 900, status: "redeemed")
    ])
    let now = Date(timeIntervalSince1970: 1_000)

    #expect(summary.effectiveAvailableCount(at: now) == 3)
    #expect(summary.availableFullResetCredits(at: now).count == 1)
    #expect(RateLimitResetCreditsSummary(availableCount: 0, credits: summary.credits)
        .effectiveAvailableCount(at: now) == 0)
}

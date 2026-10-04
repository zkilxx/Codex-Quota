import Foundation
import Testing
@testable import CodexQuota

private let countdownTestNow = Date(timeIntervalSince1970: 1_791_089_999)

@Test func resetCreditCountdownCountsDownEverySecond() {
    let expiration = countdownTestNow.addingTimeInterval(3_661)
    #expect(ResetCreditCountdownFormatter.remainingText(until: expiration, now: countdownTestNow) == "01:01:01")
    #expect(ResetCreditCountdownFormatter.remainingText(until: expiration, now: countdownTestNow.addingTimeInterval(1)) == "01:01:00")
}

@Test func resetCreditCountdownIncludesWholeDaysAndSubsecondBoundary() {
    #expect(ResetCreditCountdownFormatter.remainingText(until: countdownTestNow.addingTimeInterval(90_061), now: countdownTestNow) == "1天 01:01:01")
    #expect(ResetCreditCountdownFormatter.remainingText(until: countdownTestNow.addingTimeInterval(0.1), now: countdownTestNow) == "00:00:01")
}

@Test func resetCreditCountdownHandlesExpiredAndNonexpiringCards() {
    #expect(ResetCreditCountdownFormatter.remainingText(until: countdownTestNow, now: countdownTestNow) == "已到期")
    #expect(ResetCreditCountdownFormatter.remainingText(until: countdownTestNow.addingTimeInterval(-1), now: countdownTestNow) == "已到期")
    #expect(ResetCreditCountdownFormatter.remainingText(until: nil, now: countdownTestNow) == "长期有效")
}

@Test func resetCreditCountdownMarksOnlyValidCardsWithin24HoursAsUrgent() {
    #expect(ResetCreditCountdownFormatter.isExpiringSoon(until: countdownTestNow.addingTimeInterval(86_400), now: countdownTestNow))
    #expect(!ResetCreditCountdownFormatter.isExpiringSoon(until: countdownTestNow.addingTimeInterval(86_401), now: countdownTestNow))
    #expect(!ResetCreditCountdownFormatter.isExpiringSoon(until: countdownTestNow, now: countdownTestNow))
    #expect(!ResetCreditCountdownFormatter.isExpiringSoon(until: nil, now: countdownTestNow))
}

@Test func resetCreditExpirationUsesLocalTimeAndIncludesYearWhenNeeded() throws {
    let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let iso = ISO8601DateFormatter()
    let expiration = try #require(iso.date(from: "2026-10-04T06:01:05Z"))
    #expect(ResetCreditCountdownFormatter.expirationText(for: expiration, now: expiration, timeZone: shanghai) == "10月4日 14:01 到期")
    let nextYear = try #require(iso.date(from: "2027-01-01T00:00:00Z"))
    #expect(ResetCreditCountdownFormatter.expirationText(for: nextYear, now: expiration, timeZone: shanghai) == "2027年1月1日 08:00 到期")
}

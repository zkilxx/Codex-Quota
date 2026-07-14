import Foundation

struct RateLimitWindow: Decodable, Sendable {
    let resetsAt: Int64?
    let usedPercent: Int
    let windowDurationMins: Int64?

    var remainingPercent: Int { max(0, 100 - usedPercent) }
    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

struct RateLimitSnapshot: Decodable, Sendable {
    let limitName: String?
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

struct RateLimitResponse: Decodable, Sendable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?

    var preferredSnapshot: RateLimitSnapshot {
        rateLimitsByLimitId?["codex"] ?? rateLimits
    }
}

struct AccountTokenUsageResponse: Decodable, Sendable {
    struct DailyBucket: Decodable, Sendable {
        let startDate: String
        let tokens: Int64
    }

    let dailyUsageBuckets: [DailyBucket]?

    var todayTokens: Int64 {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: .now)
        return dailyUsageBuckets?.first(where: { $0.startDate == today })?.tokens ?? 0
    }
}

struct CodexAccountSnapshot: Sendable {
    let rateLimits: RateLimitSnapshot
    let todayTokens: Int64
}

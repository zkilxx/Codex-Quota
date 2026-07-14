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

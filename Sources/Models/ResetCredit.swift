import Foundation

struct RateLimitResetCredit: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Int64
    let expiresAt: Int64?
    let title: String?
    let description: String?

    var expirationDate: Date? {
        expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    var isFullReset: Bool { resetType == "codexRateLimits" }

    func isAvailable(at date: Date) -> Bool {
        status == "available" && isFullReset && (expirationDate.map { $0 > date } ?? true)
    }
}

struct RateLimitResetCreditsSummary: Codable, Sendable, Equatable {
    let availableCount: Int64
    let credits: [RateLimitResetCredit]?

    func availableFullResetCredits(at date: Date) -> [RateLimitResetCredit] {
        (credits ?? []).filter { $0.isAvailable(at: date) }.sorted { left, right in
            switch (left.expiresAt, right.expiresAt) {
            case let (leftExpiry?, rightExpiry?) where leftExpiry != rightExpiry:
                return leftExpiry < rightExpiry
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return left.id < right.id
            }
        }
    }

    func effectiveAvailableCount(at date: Date) -> Int64 {
        let knownExpiredCount = (credits ?? []).filter { credit in
            credit.status == "available" && (credit.expirationDate.map { $0 <= date } ?? false)
        }.count
        return max(0, max(0, availableCount) - Int64(knownExpiredCount))
    }
}

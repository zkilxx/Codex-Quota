import Foundation

enum ResetCreditCountdownFormatter {
    static func menuBarText(summary: RateLimitResetCreditsSummary?, now: Date, label: String = "重置卡") -> String? {
        guard let credit = summary?.availableFullResetCredits(at: now).first else { return nil }
        let countdown = remainingText(until: credit.expirationDate, now: now)
        return label.isEmpty ? countdown : "\(label) \(countdown)"
    }

    static func remainingText(until expiration: Date?, now: Date) -> String {
        guard let expiration else { return "长期有效" }
        let interval = expiration.timeIntervalSince(now)
        guard interval > 0 else { return "已到期" }
        let seconds = interval >= Double(Int64.max) ? Int64.max : Int64(ceil(interval))
        let days = seconds / 86_400
        let clock = String(
            format: "%02lld:%02lld:%02lld",
            (seconds % 86_400) / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60
        )
        return days > 0 ? "\(days)天 \(clock)" : clock
    }

    static func expirationText(
        for expiration: Date?,
        now: Date,
        timeZone: TimeZone = .current
    ) -> String {
        guard let expiration else { return "未设到期时间" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.component(.year, from: expiration) == calendar.component(.year, from: now)
            ? "M月d日 HH:mm"
            : "yyyy年M月d日 HH:mm"
        return "\(formatter.string(from: expiration)) 到期"
    }

    static func isExpiringSoon(until expiration: Date?, now: Date) -> Bool {
        guard let expiration else { return false }
        let remaining = expiration.timeIntervalSince(now)
        return remaining > 0 && remaining <= 86_400
    }
}

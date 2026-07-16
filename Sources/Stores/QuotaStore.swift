import Foundation
import Observation

struct UsageSample: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let tokens: Int64
}

@Observable
@MainActor
final class QuotaStore {
    private let client = CodexRateLimitClient()
    private var timer: Timer?

    var snapshot: RateLimitSnapshot?
    var todayTokens: Int64?
    var monthTokens: Int64?
    var yearTokens: Int64?
    var lastUpdated: Date?
    var errorMessage: String?
    var isRefreshing = false
    var todayHistory: [UsageSample] = []
    var monthHistory: [UsageSample] = []
    var yearHistory: [UsageSample] = []
    var onUpdate: (() -> Void)?

    init() { startRefreshing() }

    func startRefreshing() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        onUpdate?()
        Task {
            do {
                let account = try await client.fetch()
                self.snapshot = account.rateLimits
                self.todayTokens = account.todayTokens
                self.monthTokens = account.monthTokens
                self.yearTokens = account.yearTokens
                self.todayHistory = self.makeHourlyHistory(
                    buckets: account.hourlyUsageBuckets
                )
                self.monthHistory = self.makeDailyHistory(
                    buckets: account.dailyUsageBuckets
                )
                self.yearHistory = self.makeMonthlyHistory(
                    buckets: account.dailyUsageBuckets
                )
                self.lastUpdated = .now
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isRefreshing = false
            self.onUpdate?()
        }
    }

    private func makeHourlyHistory(buckets: [TokenUsageBucket]) -> [UsageSample] {
        let calendar = Calendar.current
        let now = Date.now
        let dayStart = calendar.startOfDay(for: now)
        guard let currentHour = calendar.dateInterval(of: .hour, for: now)?.start else { return [] }
        let totals = Dictionary(grouping: buckets.filter { calendar.isDate($0.startDate, inSameDayAs: now) }) {
            calendar.dateInterval(of: .hour, for: $0.startDate)?.start ?? $0.startDate
        }
        .mapValues { $0.reduce(Int64(0)) { $0 + $1.tokens } }

        return bucketSeries(
            from: dayStart,
            through: currentHour,
            component: .hour,
            totals: totals,
            calendar: calendar,
            now: now
        )
    }

    private func makeDailyHistory(buckets: [TokenUsageBucket]) -> [UsageSample] {
        let calendar = Calendar.current
        let now = Date.now
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let today = calendar.startOfDay(for: now)
        let totals = Dictionary(grouping: buckets.filter {
            $0.startDate >= monthStart && $0.startDate < (calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now)
        }) { calendar.startOfDay(for: $0.startDate) }
        .mapValues { $0.reduce(Int64(0)) { $0 + $1.tokens } }

        return bucketSeries(
            from: monthStart,
            through: today,
            component: .day,
            totals: totals,
            calendar: calendar,
            now: now
        )
    }

    private func makeMonthlyHistory(buckets: [TokenUsageBucket]) -> [UsageSample] {
        let calendar = Calendar.current
        let now = Date.now
        let start = calendar.dateInterval(of: .year, for: now)?.start ?? calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .year, value: 1, to: start) ?? now
        var monthlyTotals: [Date: Int64] = [:]
        for bucket in buckets where bucket.startDate >= start && bucket.startDate < end {
            guard let month = calendar.dateInterval(of: .month, for: bucket.startDate)?.start else { continue }
            monthlyTotals[month, default: 0] += bucket.tokens
        }
        let currentMonth = calendar.dateInterval(of: .month, for: now)?.start ?? start
        return bucketSeries(
            from: start,
            through: currentMonth,
            component: .month,
            totals: monthlyTotals,
            calendar: calendar,
            now: now
        )
    }

    private func bucketSeries(
        from start: Date,
        through lastStart: Date,
        component: Calendar.Component,
        totals: [Date: Int64],
        calendar: Calendar,
        now: Date
    ) -> [UsageSample] {
        var result: [UsageSample] = []
        var cursor = start
        while cursor <= lastStart {
            let next = calendar.date(byAdding: component, value: 1, to: cursor) ?? cursor
            result.append(UsageSample(date: cursor, tokens: totals[cursor, default: 0]))
            guard next > cursor else { break }
            cursor = next
        }
        return result
    }
}

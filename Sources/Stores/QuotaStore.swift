import Foundation
import Observation

struct UsageSample: Identifiable, Codable, Sendable {
    var id: Date { date }
    let date: Date
    let tokens: Int64
}

@Observable
@MainActor
final class QuotaStore {
    private let client = CodexRateLimitClient()
    private let remoteSync = RemoteSyncService()
    private var timer: Timer?
    private var remoteSyncConfiguration: RemoteSyncConfiguration?
    private let deviceID: String

    var snapshot: RateLimitSnapshot?
    var resetCredits: RateLimitResetCreditsSummary?
    var todayTokens: Int64?
    var monthTokens: Int64?
    var yearTokens: Int64?
    var lastUpdated: Date?
    var errorMessage: String?
    var remoteSyncState: RemoteSyncState = .disabled
    var dataSourceDescription = "本机"
    var isRefreshing = false
    var todayHistory: [UsageSample] = []
    var monthHistory: [UsageSample] = []
    var yearHistory: [UsageSample] = []
    var onUpdate: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "remoteSyncDeviceID.v1"), !existing.isEmpty {
            deviceID = existing
        } else {
            let value = UUID().uuidString.lowercased()
            defaults.set(value, forKey: "remoteSyncDeviceID.v1")
            deviceID = value
        }
        reloadRemoteSyncConfiguration()
        startRefreshing()
    }

    func reloadRemoteSyncConfiguration() {
        do {
            let configuration = try RemoteSyncConfigurationStore.load()
            guard let configuration else {
                remoteSyncConfiguration = nil
                remoteSyncState = .disabled
                onUpdate?()
                return
            }
            guard configuration != remoteSyncConfiguration else { return }
            remoteSyncConfiguration = configuration
            remoteSyncState = .syncing
            Task { [weak self] in
                await self?.pullRemoteSnapshot(configuration: configuration)
            }
        } catch {
            remoteSyncConfiguration = nil
            remoteSyncState = .unavailable(error.localizedDescription)
        }
        onUpdate?()
    }

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
                if let configuration = remoteSyncConfiguration {
                    await pullRemoteSnapshot(configuration: configuration)
                }
                let account = try await client.fetch()
                self.snapshot = account.rateLimits
                self.resetCredits = account.resetCredits
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
                let updatedAt = Date.now
                self.lastUpdated = updatedAt
                self.errorMessage = nil
                self.dataSourceDescription = "本机"
                await self.publishCurrentSnapshot(updatedAt: updatedAt)
            } catch {
                self.errorMessage = error.localizedDescription
                if let configuration = remoteSyncConfiguration {
                    await pullRemoteSnapshot(configuration: configuration)
                }
            }
            self.isRefreshing = false
            self.onUpdate?()
        }
    }

    private func publishCurrentSnapshot(updatedAt: Date) async {
        guard let configuration = remoteSyncConfiguration, let snapshot else { return }
        let remote = SyncedQuotaSnapshot(
            updatedAt: updatedAt,
            sourceDeviceID: deviceID,
            rateLimits: snapshot,
            todayTokens: todayTokens,
            monthTokens: monthTokens,
            yearTokens: yearTokens,
            todayHistory: todayHistory,
            monthHistory: monthHistory,
            yearHistory: yearHistory,
            resetCredits: resetCredits
        )
        remoteSyncState = .syncing
        do {
            try await remoteSync.push(remote, configuration: configuration)
            remoteSyncState = .synced(updatedAt)
        } catch RemoteSyncError.conflict {
            await pullRemoteSnapshot(configuration: configuration)
        } catch {
            remoteSyncState = .unavailable(error.localizedDescription)
        }
    }

    private func pullRemoteSnapshot(configuration: RemoteSyncConfiguration) async {
        remoteSyncState = .syncing
        do {
            guard let remote = try await remoteSync.pull(configuration: configuration) else {
                remoteSyncState = .ready
                onUpdate?()
                return
            }
            applyRemoteSnapshot(remote)
            remoteSyncState = .synced(remote.updatedAt)
        } catch {
            remoteSyncState = .unavailable(error.localizedDescription)
        }
        onUpdate?()
    }

    private func applyRemoteSnapshot(_ remote: SyncedQuotaSnapshot) {
        guard RemoteQuotaConflictResolver.shouldApply(
                  remoteUpdatedAt: remote.updatedAt,
                  localUpdatedAt: lastUpdated
              ) else { return }

        snapshot = remote.rateLimits
        resetCredits = remote.resetCredits
        todayTokens = remote.todayTokens
        monthTokens = remote.monthTokens
        yearTokens = remote.yearTokens
        todayHistory = remote.todayHistory
        monthHistory = remote.monthHistory
        yearHistory = remote.yearHistory
        lastUpdated = remote.updatedAt
        errorMessage = nil
        dataSourceDescription = "多端同步"
        onUpdate?()
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

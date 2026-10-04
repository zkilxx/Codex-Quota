import Foundation

struct CloudQuotaSnapshot: Codable, Sendable {
    let updatedAt: Date
    let rateLimits: RateLimitSnapshot
    let todayTokens: Int64?
    let monthTokens: Int64?
    let yearTokens: Int64?
    let todayHistory: [UsageSample]
    let monthHistory: [UsageSample]
    let yearHistory: [UsageSample]
}

@MainActor
final class ICloudSyncService {
    private let store = NSUbiquitousKeyValueStore.default
    private let snapshotKey = "quotaSnapshot.v1"
    private var changeObserver: NSObjectProtocol?
    private var isEnabled = false

    var onRemoteSnapshot: ((CloudQuotaSnapshot) -> Void)?

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled

        if enabled {
            changeObserver = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: store,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.restoreLatestSnapshot()
                }
            }
            store.synchronize()
            restoreLatestSnapshot()
        } else if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
    }

    func publish(_ snapshot: CloudQuotaSnapshot) {
        guard isEnabled,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        store.set(data, forKey: snapshotKey)
        store.synchronize()
    }

    func restoreLatestSnapshot() {
        guard isEnabled,
              let data = store.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(CloudQuotaSnapshot.self, from: data) else { return }
        onRemoteSnapshot?(snapshot)
    }
}

import Foundation
import Observation

@Observable
@MainActor
final class QuotaStore {
    private let client = CodexRateLimitClient()
    private var timer: Timer?

    var snapshot: RateLimitSnapshot?
    var lastUpdated: Date?
    var errorMessage: String?
    var isRefreshing = false
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
                let snapshot = try await client.fetch()
                self.snapshot = snapshot
                self.lastUpdated = .now
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isRefreshing = false
            self.onUpdate?()
        }
    }
}

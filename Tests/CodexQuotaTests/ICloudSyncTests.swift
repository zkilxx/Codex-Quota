import Foundation
import Testing
@testable import CodexQuota

@Test func newerRemoteSnapshotWins() {
    let local = Date(timeIntervalSince1970: 100)
    let remote = Date(timeIntervalSince1970: 101)

    #expect(RemoteQuotaConflictResolver.shouldApply(
        remoteUpdatedAt: remote,
        localUpdatedAt: local
    ))
}

@Test func staleOrEqualRemoteSnapshotDoesNotOverwriteLocalData() {
    let local = Date(timeIntervalSince1970: 100)

    #expect(!RemoteQuotaConflictResolver.shouldApply(
        remoteUpdatedAt: local,
        localUpdatedAt: local
    ))
    #expect(!RemoteQuotaConflictResolver.shouldApply(
        remoteUpdatedAt: Date(timeIntervalSince1970: 99),
        localUpdatedAt: local
    ))
}

@Test func encryptedSnapshotRoundTrips() throws {
    let key = Data((0..<32).map(UInt8.init))
    let configuration = RemoteSyncConfiguration(
        endpoint: try #require(URL(string: "https://sync.example.com")),
        syncKey: key
    )
    let snapshot = SyncedQuotaSnapshot(
        updatedAt: Date(timeIntervalSince1970: 123),
        sourceDeviceID: "test-device",
        rateLimits: RateLimitSnapshot(
            limitName: "codex",
            planType: "plus",
            primary: RateLimitWindow(
                resetsAt: 456,
                usedPercent: 25,
                windowDurationMins: 300
            ),
            secondary: nil
        ),
        todayTokens: 10,
        monthTokens: 20,
        yearTokens: 30,
        todayHistory: [UsageSample(date: Date(timeIntervalSince1970: 120), tokens: 10)],
        monthHistory: [],
        yearHistory: []
    )

    let ciphertext = try RemoteSnapshotCipher.seal(snapshot, configuration: configuration)
    let decoded = try RemoteSnapshotCipher.open(ciphertext, configuration: configuration)

    #expect(decoded.schemaVersion == SyncedQuotaSnapshot.currentSchemaVersion)
    #expect(decoded.sourceDeviceID == "test-device")
    #expect(decoded.todayTokens == 10)
    #expect(decoded.rateLimits.primary?.usedPercent == 25)
    #expect(!ciphertext.contains("test-device"))
}

@Test func sameSyncCodeDerivesStableRoutingAndAuthorization() throws {
    let key = Data(repeating: 7, count: 32)
    let first = RemoteSyncConfiguration(
        endpoint: try #require(URL(string: "https://one.example.com")),
        syncKey: key
    )
    let second = RemoteSyncConfiguration(
        endpoint: try #require(URL(string: "https://two.example.com")),
        syncKey: key
    )

    #expect(first.recordID == second.recordID)
    #expect(first.authorizationToken == second.authorizationToken)
    #expect(first.recordID.count == 32)
}

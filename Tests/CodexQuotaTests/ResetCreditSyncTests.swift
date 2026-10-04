import CryptoKit
import Foundation
import Testing
@testable import CodexQuota

@Test func encryptedQuotaSnapshotPreservesResetCreditMetadata() throws {
    let configuration = RemoteSyncConfiguration(
        endpoint: try #require(URL(string: "https://sync.example.com")),
        syncKey: Data(repeating: 7, count: 32)
    )
    let credits = RateLimitResetCreditsSummary(availableCount: 1, credits: [
        RateLimitResetCredit(
            id: "mock-sync-credit",
            resetType: "codexRateLimits",
            status: "available",
            grantedAt: 500,
            expiresAt: 2_000,
            title: "Full reset",
            description: "Test metadata"
        )
    ])
    let snapshot = SyncedQuotaSnapshot(
        updatedAt: Date(timeIntervalSince1970: 1_000),
        sourceDeviceID: "test-device",
        rateLimits: RateLimitSnapshot(limitName: nil, planType: "pro", primary: nil, secondary: nil),
        todayTokens: 10,
        monthTokens: 20,
        yearTokens: 30,
        todayHistory: [],
        monthHistory: [],
        yearHistory: [],
        resetCredits: credits
    )

    let ciphertext = try RemoteSnapshotCipher.seal(snapshot, configuration: configuration)
    let decoded = try RemoteSnapshotCipher.open(ciphertext, configuration: configuration)
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.resetCredits == credits)
    #expect(!ciphertext.contains("mock-sync-credit"))
    #expect(!ciphertext.contains("Test metadata"))
}

@Test func legacyEncryptedQuotaSnapshotDecodesWithoutResetCredits() throws {
    let configuration = RemoteSyncConfiguration(
        endpoint: try #require(URL(string: "https://sync.example.com")),
        syncKey: Data(repeating: 7, count: 32)
    )
    let legacyJSON = Data("""
    {
      "schemaVersion":1,
      "updatedAt":"2026-10-04T00:00:00Z",
      "sourceDeviceID":"legacy-device",
      "rateLimits":{"planType":"pro"},
      "todayTokens":10,
      "monthTokens":20,
      "yearTokens":30,
      "todayHistory":[],
      "monthHistory":[],
      "yearHistory":[]
    }
    """.utf8)
    let sealed = try AES.GCM.seal(legacyJSON, using: configuration.encryptionKey)
    let ciphertext = try #require(sealed.combined).base64EncodedString()
    let decoded = try RemoteSnapshotCipher.open(ciphertext, configuration: configuration)

    #expect(decoded.schemaVersion == 1)
    #expect(decoded.resetCredits == nil)
    #expect(decoded.todayTokens == 10)
    #expect(decoded.sourceDeviceID == "legacy-device")
}

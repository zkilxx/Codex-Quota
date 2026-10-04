import CryptoKit
import Foundation
import Security

struct SyncedQuotaSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let updatedAt: Date
    let sourceDeviceID: String
    let rateLimits: RateLimitSnapshot
    let todayTokens: Int64?
    let monthTokens: Int64?
    let yearTokens: Int64?
    let todayHistory: [UsageSample]
    let monthHistory: [UsageSample]
    let yearHistory: [UsageSample]
    let resetCredits: RateLimitResetCreditsSummary?

    init(
        updatedAt: Date,
        sourceDeviceID: String,
        rateLimits: RateLimitSnapshot,
        todayTokens: Int64?,
        monthTokens: Int64?,
        yearTokens: Int64?,
        todayHistory: [UsageSample],
        monthHistory: [UsageSample],
        yearHistory: [UsageSample],
        resetCredits: RateLimitResetCreditsSummary? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
        self.rateLimits = rateLimits
        self.todayTokens = todayTokens
        self.monthTokens = monthTokens
        self.yearTokens = yearTokens
        self.todayHistory = todayHistory
        self.monthHistory = monthHistory
        self.yearHistory = yearHistory
        self.resetCredits = resetCredits
    }
}

enum RemoteQuotaConflictResolver {
    static func shouldApply(remoteUpdatedAt: Date, localUpdatedAt: Date?) -> Bool {
        guard let localUpdatedAt else { return true }
        return remoteUpdatedAt > localUpdatedAt
    }
}

enum RemoteSyncState: Equatable, Sendable {
    case disabled
    case ready
    case syncing
    case synced(Date)
    case unavailable(String)
}

struct RemoteSyncConfiguration: Equatable, Sendable {
    let endpoint: URL
    let syncKey: Data

    var recordID: String {
        digest(label: "record").prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    var authorizationToken: String {
        Self.base64URL(digest(label: "authorization"))
    }

    var encryptionKey: SymmetricKey {
        SymmetricKey(data: digest(label: "encryption"))
    }

    private func digest(label: String) -> Data {
        var data = Data("codex-quota:\(label):".utf8)
        data.append(syncKey)
        return Data(SHA256.hash(data: data))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct RemoteSyncEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let updatedAt: Date
    let sourceDeviceID: String
    let ciphertext: String
}

private enum RemoteSyncJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum RemoteSyncError: LocalizedError {
    case invalidEndpoint
    case insecureEndpoint
    case missingSyncCode
    case invalidSyncCode
    case invalidResponse
    case conflict
    case server(Int, String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "同步服务地址不正确。"
        case .insecureEndpoint: "远端同步必须使用 HTTPS；本机调试可使用 http://127.0.0.1。"
        case .missingSyncCode: "请生成或输入同步码。"
        case .invalidSyncCode: "同步码格式不正确。"
        case .invalidResponse: "同步服务返回了无法识别的数据。"
        case .conflict: "云端已有更新的数据，正在重新读取。"
        case .server(let status, let message): "同步服务错误（\(status)）：\(message)"
        case .keychain(let status): "无法访问钥匙串（\(status)）。"
        }
    }
}

enum RemoteSyncConfigurationStore {
    static let enabledKey = "remoteSyncEnabled"
    static let endpointKey = "remoteSyncEndpoint"
    static let configurationDidChange = Notification.Name("CodexQuotaRemoteSyncConfigurationDidChange")

    private static let keychainService = "\(Bundle.main.bundleIdentifier ?? "CodexQuota").remote-sync"
    private static let keychainAccount = "sync-key-v1"

    static func load() throws -> RemoteSyncConfiguration? {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return nil }
        let endpointText = UserDefaults.standard.string(forKey: endpointKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let endpoint = URL(string: endpointText), endpoint.host != nil else {
            throw RemoteSyncError.invalidEndpoint
        }
        let isLoopback = ["127.0.0.1", "localhost", "::1"].contains(endpoint.host?.lowercased() ?? "")
        guard endpoint.scheme?.lowercased() == "https" || (endpoint.scheme?.lowercased() == "http" && isLoopback) else {
            throw RemoteSyncError.insecureEndpoint
        }
        guard let code = try loadSyncCode(), !code.isEmpty else {
            throw RemoteSyncError.missingSyncCode
        }
        return RemoteSyncConfiguration(endpoint: endpoint, syncKey: try decodeSyncCode(code))
    }

    static func loadSyncCode() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw RemoteSyncError.keychain(status)
        }
        return value
    }

    static func saveSyncCode(_ code: String) throws {
        _ = try decodeSyncCode(code)
        let data = Data(code.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw RemoteSyncError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw RemoteSyncError.keychain(updateStatus)
        }
        NotificationCenter.default.post(name: configurationDidChange, object: nil)
    }

    static func generateSyncCode() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RemoteSyncError.invalidSyncCode
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeSyncCode(_ code: String) throws -> Data {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized + padding), data.count == 32 else {
            throw RemoteSyncError.invalidSyncCode
        }
        return data
    }
}

enum RemoteSnapshotCipher {
    static func seal(_ snapshot: SyncedQuotaSnapshot, configuration: RemoteSyncConfiguration) throws -> String {
        let plaintext = try RemoteSyncJSON.encoder().encode(snapshot)
        let sealed = try AES.GCM.seal(plaintext, using: configuration.encryptionKey)
        guard let combined = sealed.combined else { throw RemoteSyncError.invalidResponse }
        return combined.base64EncodedString()
    }

    static func open(_ ciphertext: String, configuration: RemoteSyncConfiguration) throws -> SyncedQuotaSnapshot {
        guard let combined = Data(base64Encoded: ciphertext) else { throw RemoteSyncError.invalidResponse }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: configuration.encryptionKey)
        let snapshot = try RemoteSyncJSON.decoder().decode(SyncedQuotaSnapshot.self, from: plaintext)
        guard snapshot.schemaVersion == SyncedQuotaSnapshot.currentSchemaVersion else {
            throw RemoteSyncError.invalidResponse
        }
        return snapshot
    }
}

actor RemoteSyncService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func pull(configuration: RemoteSyncConfiguration) async throws -> SyncedQuotaSnapshot? {
        var request = authorizedRequest(configuration: configuration)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteSyncError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else {
            throw RemoteSyncError.server(http.statusCode, responseMessage(data))
        }
        let envelope = try RemoteSyncJSON.decoder().decode(RemoteSyncEnvelope.self, from: data)
        let snapshot = try RemoteSnapshotCipher.open(envelope.ciphertext, configuration: configuration)
        guard envelope.schemaVersion == snapshot.schemaVersion,
              envelope.sourceDeviceID == snapshot.sourceDeviceID,
              envelope.updatedAt == snapshot.updatedAt else {
            throw RemoteSyncError.invalidResponse
        }
        return snapshot
    }

    func push(_ snapshot: SyncedQuotaSnapshot, configuration: RemoteSyncConfiguration) async throws {
        let envelope = RemoteSyncEnvelope(
            schemaVersion: snapshot.schemaVersion,
            updatedAt: snapshot.updatedAt,
            sourceDeviceID: snapshot.sourceDeviceID,
            ciphertext: try RemoteSnapshotCipher.seal(snapshot, configuration: configuration)
        )
        var request = authorizedRequest(configuration: configuration)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try RemoteSyncJSON.encoder().encode(envelope)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteSyncError.invalidResponse }
        if http.statusCode == 409 { throw RemoteSyncError.conflict }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteSyncError.server(http.statusCode, responseMessage(data))
        }
    }

    private func authorizedRequest(configuration: RemoteSyncConfiguration) -> URLRequest {
        let url = configuration.endpoint
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(configuration.recordID)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(configuration.authorizationToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func responseMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "未知错误"
    }
}

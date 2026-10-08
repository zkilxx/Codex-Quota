import Foundation

enum ResetCreditConsumeOutcome: String, Codable, Sendable {
    case reset
    case nothingToReset
    case noCredit
    case alreadyRedeemed
}

enum CodexResetCreditError: LocalizedError {
    case executableNotFound
    case invalidResponse
    case invalidArguments
    case timeout
    case server(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "未找到 Codex。请先安装或打开 Codex 桌面版。"
        case .invalidResponse: "Codex 返回了无法识别的重置卡数据。"
        case .invalidArguments: "缺少重置卡标识或请求标识。"
        case .timeout: "读取或使用重置卡超时，请稍后重试。"
        case .server(let message): message
        }
    }
}

actor CodexResetCreditClient {
    private struct ConsumeResponse: Decodable {
        let outcome: ResetCreditConsumeOutcome
    }

    func read() async throws -> RateLimitResponse {
        let data = try await request(
            method: "account/rateLimits/read",
            params: ["excludeResetCreditDetails": false]
        )
        guard let response = try? JSONDecoder().decode(RateLimitResponse.self, from: data) else {
            throw CodexResetCreditError.invalidResponse
        }
        return response
    }

    func consume(creditID: String, idempotencyKey: String) async throws -> ResetCreditConsumeOutcome {
        guard !creditID.isEmpty,
              !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexResetCreditError.invalidArguments
        }
        let data = try await request(
            method: "account/rateLimitResetCredit/consume",
            params: ["creditId": creditID, "idempotencyKey": idempotencyKey]
        )
        guard let response = try? JSONDecoder().decode(ConsumeResponse.self, from: data) else {
            throw CodexResetCreditError.invalidResponse
        }
        return response.outcome
    }

    private func request(method: String, params: [String: Any]) async throws -> Data {
        guard let executable = CodexExecutableLocator.resolve() else {
            throw CodexResetCreditError.executableNotFound
        }
        let requestData = try JSONSerialization.data(withJSONObject: [
            "id": 2, "method": method, "params": params
        ])
        let session = ResetCreditAppServerSession(executable: executable, request: requestData)
        let worker = Task.detached(priority: .userInitiated) {
            try session.perform()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            session.cancel()
            worker.cancel()
        }
    }
}

// Pipe I/O belongs to one detached worker; the lock protects watchdog/cancellation
// access to the process lifecycle and terminal state.
private final class ResetCreditAppServerSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let request: Data
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private var timedOut = false
    private var cancelled = false

    init(executable: String, request: Data) {
        self.request = request
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func perform() throws -> Data {
        let watchdog = DispatchWorkItem { [weak self] in self?.expire() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: watchdog)
        defer {
            watchdog.cancel()
            finish()
        }
        do {
            try lock.withLock {
                if cancelled { throw CancellationError() }
                if timedOut { throw CodexResetCreditError.timeout }
                try process.run()
            }
            let initialize = try JSONSerialization.data(withJSONObject: [
                "id": 1,
                "method": "initialize",
                "params": ["clientInfo": ["name": "CodexQuota", "version": "1.1.1"]]
            ])
            try send(initialize)
            _ = try readResult(id: 1)
            try send(Data("{\"method\":\"initialized\"}".utf8))
            try send(request)
            let result = try readResult(id: 2)
            try lock.withLock {
                if timedOut { throw CodexResetCreditError.timeout }
                if cancelled { throw CancellationError() }
                finished = true
            }
            return result
        } catch {
            let stopError: (any Error)? = lock.withLock {
                if timedOut { return CodexResetCreditError.timeout }
                if cancelled { return CancellationError() }
                return nil
            }
            throw stopError ?? error
        }
    }

    func cancel() {
        lock.withLock {
            guard !finished else { return }
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    private func expire() {
        lock.withLock {
            guard !finished else { return }
            timedOut = true
            if process.isRunning { process.terminate() }
        }
    }

    private func finish() {
        lock.withLock {
            finished = true
            if process.isRunning { process.terminate() }
        }
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    private func send(_ data: Data) throws {
        var line = data
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    private func readResult(id: Int) throws -> Data {
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer.prefix(upTo: newline))
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["id"] as? Int == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw CodexResetCreditError.server(
                        error["message"] as? String ?? "Codex 无法完成重置卡请求。"
                    )
                }
                guard let result = object["result"] as? [String: Any] else {
                    throw CodexResetCreditError.invalidResponse
                }
                return try JSONSerialization.data(withJSONObject: result)
            }
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { throw CodexResetCreditError.invalidResponse }
            buffer.append(data)
        }
    }
}

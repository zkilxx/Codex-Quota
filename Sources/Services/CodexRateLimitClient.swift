import Foundation

enum CodexRateLimitError: LocalizedError {
    case executableNotFound
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "未找到 Codex。请先安装或打开 Codex 桌面版。"
        case .invalidResponse: "Codex 返回了无法识别的限额数据。"
        case .server(let message): message
        }
    }
}

actor CodexRateLimitClient {
    func fetch() async throws -> CodexAccountSnapshot {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let executable = try codexExecutable()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]

        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "CodexQuota", "version": "1.0"]
        ]], to: input.fileHandleForWriting)
        _ = try readResponse(id: 1, from: output.fileHandleForReading)

        try send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()], to: input.fileHandleForWriting)
        let response = try readResponse(id: 2, from: output.fileHandleForReading)
        guard let result = response["result"] else { throw CodexRateLimitError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: result)
        let rateLimits = try JSONDecoder().decode(RateLimitResponse.self, from: data).preferredSnapshot

        try send(["id": 3, "method": "account/usage/read", "params": NSNull()], to: input.fileHandleForWriting)
        let usageResponse = try readResponse(id: 3, from: output.fileHandleForReading)
        guard let usageResult = usageResponse["result"] else { throw CodexRateLimitError.invalidResponse }
        let usageData = try JSONSerialization.data(withJSONObject: usageResult)
        let usage = try JSONDecoder().decode(AccountTokenUsageResponse.self, from: usageData)
        return CodexAccountSnapshot(rateLimits: rateLimits, todayTokens: usage.todayTokens)
    }

    private func codexExecutable() throws -> String {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        throw CodexRateLimitError.executableNotFound
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func readResponse(id: Int, from handle: FileHandle) throws -> [String: Any] {
        var buffer = Data()
        while true {
            let data = handle.availableData
            guard !data.isEmpty else { throw CodexRateLimitError.invalidResponse }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if let responseID = object["id"] as? Int, responseID == id {
                    if let error = object["error"] { throw CodexRateLimitError.server("Codex: \(error)") }
                    return object
                }
            }
        }
    }
}

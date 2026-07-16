import Foundation

actor LocalTokenUsageReader {
    struct Snapshot: Sendable {
        let total: Int64
        let hourlyBuckets: [TokenUsageBucket]
    }

    private struct FileState {
        var offset: UInt64 = 0
        var remainder = Data()
        var lastTotal: Int64?
        var todayTotal: Int64 = 0
        var hourlyTotals: [Date: Int64] = [:]
    }

    private var dayStart = Calendar.current.startOfDay(for: .now)
    private var states: [String: FileState] = [:]
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func todayUsage() -> Snapshot {
        let currentDayStart = Calendar.current.startOfDay(for: .now)
        if currentDayStart != dayStart {
            dayStart = currentDayStart
            states.removeAll()
        }

        for file in sessionFilesModifiedToday() {
            update(file)
        }
        var hourlyTotals: [Date: Int64] = [:]
        for state in states.values {
            for (hour, tokens) in state.hourlyTotals {
                hourlyTotals[hour, default: 0] += tokens
            }
        }
        return Snapshot(
            total: states.values.reduce(0) { $0 + $1.todayTotal },
            hourlyBuckets: hourlyTotals
                .map { TokenUsageBucket(startDate: $0.key, tokens: $0.value) }
                .sorted { $0.startDate < $1.startDate }
        )
    }

    private func sessionFilesModifiedToday() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var files: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified >= dayStart else { continue }
                files.append(file)
            }
        }
        return files
    }

    private func update(_ file: URL) {
        let key = file.path
        var state = states[key] ?? FileState()
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.offset)
            guard let newData = try handle.readToEnd(), !newData.isEmpty else {
                states[key] = state
                return
            }
            state.offset += UInt64(newData.count)
            state.remainder.append(newData)
            let lines = state.remainder.split(separator: 0x0A, omittingEmptySubsequences: false)
            state.remainder = lines.last.map { Data($0) } ?? Data()
            for line in lines.dropLast() {
                consume(Data(line), into: &state)
            }
            states[key] = state
        } catch {
            states[key] = state
        }
    }

    private func consume(_ line: Data, into state: inout FileState) {
        guard line.range(of: Data("\"token_count\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let date = dateFormatter.date(from: timestamp),
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any],
              let number = usage["total_tokens"] as? NSNumber else { return }

        let total = number.int64Value
        if date >= dayStart {
            let delta = max(0, total - (state.lastTotal ?? 0))
            state.todayTotal += delta
            if delta > 0, let hour = Calendar.current.dateInterval(of: .hour, for: date)?.start {
                state.hourlyTotals[hour, default: 0] += delta
            }
        }
        state.lastTotal = total
    }
}

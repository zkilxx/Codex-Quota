import Foundation

enum CodexExecutableLocator {
    static func resolve(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        ]
        let bundledPaths = applicationDirectories.flatMap { directory in
            ["ChatGPT.app", "Codex.app"].flatMap { app in
                let resources = directory
                    .appendingPathComponent(app, isDirectory: true)
                    .appendingPathComponent("Contents/Resources", isDirectory: true)
                return [
                    resources.appendingPathComponent("codex-cli/CodexCLI.app/Contents/MacOS/codex").path,
                    resources.appendingPathComponent("codex").path
                ]
            }
        }
        let installedPaths = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            homeDirectory.appendingPathComponent(".local/bin/codex").path,
            homeDirectory.appendingPathComponent("bin/codex").path
        ]
        let searchPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex").path }

        return (bundledPaths + installedPaths + searchPaths).first(where: isExecutable)
    }
}

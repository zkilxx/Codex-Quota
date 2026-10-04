import Foundation
import Testing
@testable import CodexQuota

private let executableTestHome = URL(fileURLWithPath: "/Users/codex-quota-test", isDirectory: true)

@Test func modernBundledCodexExecutableWinsOverLegacyAndInstalledCLI() {
    let modern = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    let available = Set([
        modern,
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/usr/local/bin/codex"
    ])

    #expect(CodexExecutableLocator.resolve(
        homeDirectory: executableTestHome,
        environment: [:],
        isExecutable: available.contains
    ) == modern)
}

@Test func legacyBundledCodexExecutableRemainsSupported() {
    let legacy = "/Applications/ChatGPT.app/Contents/Resources/codex"

    #expect(CodexExecutableLocator.resolve(
        homeDirectory: executableTestHome,
        environment: [:],
        isExecutable: { $0 == legacy }
    ) == legacy)
}

@Test(arguments: [
    "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
    "/Users/codex-quota-test/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    "/Users/codex-quota-test/Applications/ChatGPT.app/Contents/Resources/codex",
    "/Users/codex-quota-test/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    "/Users/codex-quota-test/Applications/Codex.app/Contents/Resources/codex"
])
func alternativeBundledCodexLocationsAreSupported(path: String) {
    #expect(CodexExecutableLocator.resolve(
        homeDirectory: executableTestHome,
        environment: [:],
        isExecutable: { $0 == path }
    ) == path)
}

@Test func codexExecutableFallsBackToPATH() {
    let available = Set(["/custom/first/codex", "/custom/second/codex"])

    #expect(CodexExecutableLocator.resolve(
        homeDirectory: executableTestHome,
        environment: ["PATH": "/custom/first:/custom/second"],
        isExecutable: available.contains
    ) == "/custom/first/codex")
}

@Test func missingCodexExecutableReturnsNil() {
    #expect(CodexExecutableLocator.resolve(
        homeDirectory: executableTestHome,
        environment: ["PATH": "/custom/bin"],
        isExecutable: { _ in false }
    ) == nil)
}

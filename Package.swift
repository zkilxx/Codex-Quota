// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Codex Quota",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexQuota", targets: ["CodexQuota"])],
    targets: [.executableTarget(name: "CodexQuota", path: "Sources")]
)

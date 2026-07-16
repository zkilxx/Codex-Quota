import AppKit
import Foundation
import SwiftUI

struct AboutView: View {
    private enum UpdateState: Equatable {
        case idle
        case checking
        case current(current: String, latest: String)
        case available(version: String, url: URL)
        case failed

        var message: String {
            switch self {
            case .idle: "可前往 GitHub 检查新版本"
            case .checking: "正在连接 GitHub…"
            case .current(let current, let latest): "当前 \(current)，GitHub 最新 \(latest)"
            case .available(let version, _): "发现新版本 \(version)"
            case .failed: "暂时无法检查，请稍后重试"
            }
        }

    }

    @State private var updateState = UpdateState.idle

    private let repositoryURL = URL(string: "https://github.com/zkilxx/Codex-Quota")!
    private let latestReleaseURL = URL(string: "https://github.com/zkilxx/Codex-Quota/releases/latest")!
    private let accent = Color(red: 0.04, green: 0.67, blue: 0.46)

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 68, height: 68)
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)

                VStack(spacing: 4) {
                    Text("Codex Quota")
                        .font(.system(size: 22, weight: .semibold))
                    Text("版本 \(currentVersion)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                informationRow(title: "作者", value: "zkilxx")
                Divider().opacity(0.25).padding(.leading, 74)
                informationRow(title: "许可证", value: "Apache-2.0")
                Divider().opacity(0.25).padding(.leading, 74)
                informationRow(title: "版权", value: "© 2026 zkilxx")
            }
            .padding(.horizontal, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        Task { await checkForUpdates() }
                    } label: {
                        Label(updateButtonTitle, systemImage: updateButtonSymbol)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(AboutActionButtonStyle(accent: accent))
                    .disabled(updateState == .checking)

                    Button { NSWorkspace.shared.open(repositoryURL) } label: {
                        Label("GitHub 项目", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(AboutActionButtonStyle(accent: accent))
                }

                Button {
                    switch updateState {
                    case .available(_, let url): NSWorkspace.shared.open(url)
                    case .failed: NSWorkspace.shared.open(latestReleaseURL)
                    default: break
                    }
                } label: {
                    HStack(spacing: 6) {
                        if updateState == .checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: updateStatusSymbol)
                        }
                        Text(updateState.message)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(updateStatusColor)
                }
                .buttonStyle(.plain)
                .disabled(!statusActionEnabled)
            }

            Text("轻量、私密的 macOS Codex 用量与额度工具")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, PanelLayoutMetrics.horizontalInset)
        .padding(.top, PanelLayoutMetrics.topInset)
        .padding(.bottom, PanelLayoutMetrics.bottomInset)
    }

    private func informationRow(title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 12))
        .frame(height: 38)
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
    }

    private var updateButtonTitle: String {
        switch updateState {
        case .checking: "正在检查…"
        case .current: "已是最新版本"
        case .available: "发现新版本"
        case .failed: "重新检查"
        case .idle: "检查更新"
        }
    }

    private var updateButtonSymbol: String {
        updateState == .checking ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
    }

    private var updateStatusSymbol: String {
        switch updateState {
        case .available: "arrow.down.circle.fill"
        case .current: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        default: "info.circle"
        }
    }

    private var updateStatusColor: Color {
        switch updateState {
        case .available, .current: accent
        case .failed: .orange
        default: .secondary
        }
    }

    private var statusActionEnabled: Bool {
        switch updateState {
        case .available, .failed: true
        default: false
        }
    }

    @MainActor
    private func checkForUpdates() async {
        withAnimation(.easeInOut(duration: 0.2)) { updateState = .checking }
        do {
            let releaseURL = try await resolveLatestReleaseURL()
            let latest = releaseURL.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let state: UpdateState = latest.compare(currentVersion, options: .numeric) == .orderedDescending
                ? .available(version: latest, url: releaseURL)
                : .current(current: currentVersion, latest: latest)
            withAnimation(.easeInOut(duration: 0.28)) { updateState = state }
        } catch {
            withAnimation(.easeInOut(duration: 0.28)) { updateState = .failed }
        }
    }

    private func resolveLatestReleaseURL() async throws -> URL {
        do {
            return try await releaseURL(using: "HEAD")
        } catch {
            return try await releaseURL(using: "GET")
        }
    }

    private func releaseURL(using method: String) async throws -> URL {
        var request = URLRequest(
            url: latestReleaseURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 12
        )
        request.httpMethod = method
        request.setValue("Codex-Quota/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<400).contains(response.statusCode),
              let releaseURL = response.url,
              releaseURL.path.contains("/releases/tag/") else {
            throw URLError(.badServerResponse)
        }
        return releaseURL
    }
}

private struct AboutActionButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? accent : Color.primary)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.11 : 0.055),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.7)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

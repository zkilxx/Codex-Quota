import SwiftUI

struct QuotaMenuView: View {
    let store: QuotaStore

    var body: some View {
        Group {
            if let snapshot = store.snapshot {
                quotaSection(snapshot)
            } else if let errorMessage = store.errorMessage {
                Text(errorMessage)
                Button("重新尝试") { store.refresh() }
            } else {
                Text("正在读取 Codex 限额…")
            }

            Divider()
            if let lastUpdated = store.lastUpdated {
                Text("更新于 \(lastUpdated, format: .dateTime.hour().minute().second())")
            }
            Button(store.isRefreshing ? "正在刷新…" : "立即刷新") { store.refresh() }
                .disabled(store.isRefreshing)
                .keyboardShortcut("r")
            Link("打开 Codex 用量设置", destination: URL(string: "https://chatgpt.com/codex/settings/usage")!)
            Divider()
            Button("退出 Codex Quota") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private func quotaSection(_ snapshot: RateLimitSnapshot) -> some View {
        if let primary = snapshot.primary {
            quotaRow(title: primaryTitle(primary), window: primary)
        }
        if let secondary = snapshot.secondary {
            quotaRow(title: secondaryTitle(secondary), window: secondary)
        }
        if snapshot.primary == nil && snapshot.secondary == nil {
            Text("当前方案不返回限额窗口")
        }
    }

    private func quotaRow(title: String, window: RateLimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title)：剩余 \(window.remainingPercent)%")
            if let resetDate = window.resetDate {
                Text("刷新 \(resetDate, format: .dateTime.month().day().hour().minute())")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func primaryTitle(_ window: RateLimitWindow) -> String {
        window.windowDurationMins.map { "\($0) 分钟额度" } ?? "短期额度"
    }

    private func secondaryTitle(_ window: RateLimitWindow) -> String {
        window.windowDurationMins.map { "\($0 / 60) 小时额度" } ?? "长期额度"
    }
}

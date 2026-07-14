import SwiftUI

struct SettingsView: View {
    @AppStorage("showFiveHourQuota") private var showFiveHourQuota = true
    @AppStorage("showWeeklyQuota") private var showWeeklyQuota = true
    @AppStorage("showMonthlyQuota") private var showMonthlyQuota = true

    var body: some View {
        Form {
            Section("状态栏显示") {
                Toggle("5 小时额度", isOn: $showFiveHourQuota)
                Toggle("1 周额度", isOn: $showWeeklyQuota)
                Toggle("1 月额度", isOn: $showMonthlyQuota)
            }
            Text("仅当 Codex 返回对应的额度窗口时，项目才会显示在状态栏中。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 330)
    }
}

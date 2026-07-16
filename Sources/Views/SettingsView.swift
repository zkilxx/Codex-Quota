import SwiftUI

struct SettingsView: View {
    let onEditLabels: () -> Void
    let themeDarkAmount: Double?

    @AppStorage("interfaceAppearance") private var interfaceAppearance = InterfaceAppearance.system.rawValue
    @AppStorage("showTodayTokens") private var showTodayTokens = true
    @AppStorage("showMonthTokens") private var showMonthTokens = false
    @AppStorage("showYearTokens") private var showYearTokens = false
    @AppStorage("showFiveHourQuota") private var showFiveHourQuota = true
    @AppStorage("showWeeklyQuota") private var showWeeklyQuota = true
    @AppStorage("showMonthlyQuota") private var showMonthlyQuota = true
    @AppStorage("showResetCountdown") private var showResetCountdown = true
    @AppStorage("useCustomLabels") private var useCustomLabels = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var displayedAppearance: InterfaceAppearance

    private let accent = Color(red: 0.04, green: 0.67, blue: 0.46)
    private let ink = Color(red: 0.04, green: 0.12, blue: 0.24)

    init(onEditLabels: @escaping () -> Void, themeDarkAmount: Double? = nil) {
        self.onEditLabels = onEditLabels
        self.themeDarkAmount = themeDarkAmount
        let stored = UserDefaults.standard.string(forKey: "interfaceAppearance") ?? InterfaceAppearance.system.rawValue
        _displayedAppearance = State(
            initialValue: InterfaceAppearance(rawValue: stored) ?? .system
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                appearanceSection
                Divider().opacity(0.28).padding(.horizontal, 13)
                visibleItemsSection
                Divider().opacity(0.28).padding(.horizontal, 13)
                optionsSection
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(surfaceBorder, lineWidth: 0.7)
            }

            Text("所有更改都会立即应用到菜单栏和程序面板。")
                .font(.caption2)
                .foregroundStyle(secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            Spacer(minLength: 0)
        }
        .onChange(of: interfaceAppearance) { _, newValue in
            guard let appearance = InterfaceAppearance(rawValue: newValue),
                  appearance != displayedAppearance else { return }
            withAnimation(.smooth(duration: 0.34)) { displayedAppearance = appearance }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("面板外观")
            ZStack(alignment: .leading) {
                GeometryReader { proxy in
                    let spacing: CGFloat = 2
                    let segmentWidth = (proxy.size.width - spacing * 2) / 3
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(segmentedSelectionFill)
                        .frame(width: segmentWidth, height: 28)
                        .offset(
                            x: CGFloat(displayedAppearanceIndex) * (segmentWidth + spacing)
                        )
                }
                .allowsHitTesting(false)

                HStack(spacing: 2) {
                    ForEach(InterfaceAppearance.allCases) { appearance in
                        Button {
                            selectAppearance(appearance)
                        } label: {
                            Text(appearance.title)
                                .font(.caption.weight(displayedAppearance == appearance ? .semibold : .regular))
                                .foregroundStyle(displayedAppearance == appearance ? primaryText : secondaryText)
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(AnimatedSegmentButtonStyle())
                    }
                }
            }
            .frame(height: 28)
            .padding(2)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(surfaceBorder, lineWidth: 0.6)
            }
        }
        .padding(16)
    }

    private var visibleItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("菜单栏显示内容")

            HStack(alignment: .top, spacing: 24) {
                checkboxColumn(title: "Token") {
                    checkbox("今日", isOn: $showTodayTokens)
                    checkbox("本月", isOn: $showMonthTokens)
                    checkbox("本年", isOn: $showYearTokens)
                }

                Divider().frame(height: 84).opacity(0.3)

                checkboxColumn(title: "额度") {
                    checkbox("5 小时", isOn: $showFiveHourQuota)
                    checkbox("1 周", isOn: $showWeeklyQuota)
                    checkbox("1 月", isOn: $showMonthlyQuota)
                }
            }
        }
        .padding(16)
    }

    private var optionsSection: some View {
        VStack(spacing: 0) {
            fullWidthToggle(
                title: "显示刷新倒计时",
                subtitle: "在额度百分比后显示剩余时间",
                isOn: $showResetCountdown
            )

            Divider().opacity(0.3).padding(.leading, 12)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("状态栏文字")
                        .font(.subheadline.weight(.medium))
                    Text("默认标签或自定义文字")
                        .font(.caption2)
                        .foregroundStyle(secondaryText)
                }
                Spacer()
                textModeSelector
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 58)

            VStack(spacing: 0) {
                Divider().opacity(0.3).padding(.leading, 12)

                Button(action: onEditLabels) {
                    HStack {
                        Text("编辑自定义文字")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(secondaryText)
                    }
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FrostedSettingsRowButtonStyle())
                .disabled(!useCustomLabels)
            }
            .opacity(useCustomLabels ? 1 : 0.42)
            .animation(.easeInOut(duration: 0.24), value: useCustomLabels)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(secondaryText)
    }

    private func checkboxColumn<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checkbox(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(accent)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func fullWidthToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .tint(accent)
        .controlSize(.mini)
        .padding(.horizontal, 13)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }

    private var textModeSelector: some View {
        ZStack(alignment: .leading) {
            GeometryReader { proxy in
                let inset: CGFloat = 2
                let spacing: CGFloat = 2
                let segmentWidth = (proxy.size.width - inset * 2 - spacing) / 2

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(segmentedSelectionFill)
                    .frame(width: segmentWidth, height: 24)
                    .offset(
                        x: inset + (useCustomLabels ? segmentWidth + spacing : 0),
                        y: inset
                    )
            }
            .allowsHitTesting(false)

            HStack(spacing: 2) {
                textModeButton("默认", value: false)
                textModeButton("自定义", value: true)
            }
            .padding(2)
        }
        .frame(width: 118, height: 28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(surfaceBorder, lineWidth: 0.6)
        }
        .animation(.smooth(duration: 0.34), value: useCustomLabels)
    }

    private func textModeButton(_ title: String, value: Bool) -> some View {
        Button {
            guard useCustomLabels != value else { return }
            useCustomLabels = value
        } label: {
            Text(title)
                .font(.caption.weight(useCustomLabels == value ? .semibold : .regular))
                .foregroundStyle(useCustomLabels == value ? primaryText : secondaryText)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(AnimatedSegmentButtonStyle())
    }

    private func selectAppearance(_ appearance: InterfaceAppearance) {
        guard appearance != displayedAppearance else { return }
        withAnimation(.smooth(duration: 0.34)) {
            displayedAppearance = appearance
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            interfaceAppearance = appearance.rawValue
        }
    }

    private var displayedAppearanceIndex: Int {
        InterfaceAppearance.allCases.firstIndex(of: displayedAppearance) ?? 0
    }

    private var primaryText: Color {
        Color(
            red: mix(0.04, 0.94),
            green: mix(0.12, 0.94),
            blue: mix(0.24, 0.94)
        )
    }

    private var segmentedSelectionFill: Color {
        Color.white.opacity(mix(0.88, 0.13))
    }

    private var secondaryText: Color {
        Color(
            red: mix(0.405, 0.68),
            green: mix(0.454, 0.68),
            blue: mix(0.529, 0.68)
        )
    }

    private var surfaceBorder: Color {
        Color.white.opacity(mix(0.10, 0.11))
    }

    private var resolvedDarkAmount: Double {
        themeDarkAmount ?? (colorScheme == .dark ? 1 : 0)
    }

    private func mix(_ light: Double, _ dark: Double) -> Double {
        light + (dark - light) * resolvedDarkAmount
    }
}

private struct AnimatedSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CustomLabelsView: View {
    @AppStorage("customAppLabel") private var customAppLabel = "Codex"
    @AppStorage("customTodayLabel") private var customTodayLabel = "今日"
    @AppStorage("customMonthLabel") private var customMonthLabel = "本月"
    @AppStorage("customYearLabel") private var customYearLabel = "本年"
    @AppStorage("customFiveHourLabel") private var customFiveHourLabel = "5时"
    @AppStorage("customWeekLabel") private var customWeekLabel = "1周"
    @AppStorage("customMonthQuotaLabel") private var customMonthQuotaLabel = "1月"
    @Environment(\.colorScheme) private var colorScheme

    private let ink = Color(red: 0.04, green: 0.12, blue: 0.24)

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                Text("状态栏标签")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(secondaryText)

                labelField("应用前缀", text: $customAppLabel, prompt: "Codex")
                Divider().opacity(0.25)
                labelField("今日", text: $customTodayLabel, prompt: "今日")
                labelField("本月", text: $customMonthLabel, prompt: "本月")
                labelField("本年", text: $customYearLabel, prompt: "本年")
                Divider().opacity(0.25)
                labelField("5 小时", text: $customFiveHourLabel, prompt: "5时")
                labelField("1 周", text: $customWeekLabel, prompt: "1周")
                labelField("1 月", text: $customMonthQuotaLabel, prompt: "1月")
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(surfaceBorder, lineWidth: 0.7)
            }

            Text("留空某项时，菜单栏只显示对应数值。修改会自动保存。")
                .font(.caption2)
                .foregroundStyle(secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            Spacer(minLength: 0)
        }
    }

    private func labelField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(secondaryText)
                .frame(width: 58, alignment: .trailing)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .rounded))
        }
        .frame(minHeight: 28)
    }

    private var secondaryText: Color {
        colorScheme == .dark ? .white.opacity(0.68) : ink.opacity(0.62)
    }

    private var surfaceBorder: Color {
        colorScheme == .dark ? .white.opacity(0.11) : ink.opacity(0.10)
    }
}

private struct FrostedSettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
    }
}

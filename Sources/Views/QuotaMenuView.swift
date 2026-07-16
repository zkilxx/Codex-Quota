import AppKit
import SwiftUI

enum QuotaMenuPage {
    case overview
    case statusBarDisplay
    case customLabels
    case about
}

enum InterfaceAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct QuotaMenuView: View {
    let store: QuotaStore
    let onClose: () -> Void
    let onPreferredHeightChange: (CGFloat) -> Void

    @State private var page: QuotaMenuPage
    @AppStorage("interfaceAppearance") private var interfaceAppearance = InterfaceAppearance.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private let accent = Color(red: 0.10, green: 0.64, blue: 0.39)

    init(
        store: QuotaStore,
        initialPage: QuotaMenuPage = .overview,
        onClose: @escaping () -> Void = {},
        onPreferredHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.store = store
        self.onClose = onClose
        self.onPreferredHeightChange = onPreferredHeightChange
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            pageContent
        }
        .padding(16)
        .frame(width: 420, height: preferredHeight, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .tint(accent)
        .preferredColorScheme(selectedAppearance.colorScheme)
        .onAppear { onPreferredHeightChange(preferredHeight) }
        .onChange(of: page) { _, _ in onPreferredHeightChange(preferredHeight) }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .overview:
            overview.transition(.opacity)
        case .statusBarDisplay:
            SettingsView(onEditLabels: { navigate(to: .customLabels) })
                .transition(.opacity)
        case .customLabels:
            CustomLabelsView()
                .transition(.opacity)
        case .about:
            AboutView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if page == .overview {
                Image(systemName: "gauge.high")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .frostedSurface(cornerRadius: 11, shadow: false)
            } else {
                Button { navigateBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FrostedIconButtonStyle())
                .help("返回")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(pageTitle)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                if page == .overview {
                    Text("用量与额度")
                        .font(.caption2)
                        .foregroundStyle(secondaryText)
                }
            }

            Spacer()

            if page == .overview {
                HStack(spacing: 5) {
                    Circle()
                        .fill(store.errorMessage == nil ? accent : .orange)
                        .frame(width: 6, height: 6)
                    Text(store.errorMessage == nil ? "已连接" : "需检查")
                        .font(.caption2)
                        .foregroundStyle(secondaryText)
                }

                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                        .animation(
                            store.isRefreshing
                                ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                : .default,
                            value: store.isRefreshing
                        )
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FrostedIconButtonStyle())
                .disabled(store.isRefreshing)
                .help("立即刷新")
                .keyboardShortcut("r")
            }
        }
        .frame(height: 36)
    }

    private var overview: some View {
        VStack(spacing: 12) {
            todaySummary
            periodSummary
            quotaSummary
            Spacer(minLength: 0)
            primaryActions
            footer
        }
    }

    private var todaySummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("今日 Token")
                    .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryText)
                Spacer()
                Text(store.todayTokens.map { "约 \(estimatedDollars($0))" } ?? "约 $—")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(accent)
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(store.todayTokens.map(formattedTokens) ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("Token")
                    .font(.caption)
                        .foregroundStyle(secondaryText)
            }

            Text("美元金额为模拟估算，并非实际账单")
                .font(.caption2)
                .foregroundStyle(tertiaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedSurface(cornerRadius: 16)
    }

    private var periodSummary: some View {
        HStack(spacing: 0) {
            periodMetric(title: "本月", symbol: "calendar", tokens: store.monthTokens)
            Divider().frame(height: 46).opacity(0.35)
            periodMetric(title: "本年", symbol: "calendar.badge.clock", tokens: store.yearTokens)
        }
        .padding(.vertical, 10)
        .frostedSurface(cornerRadius: 14)
    }

    private func periodMetric(title: String, symbol: String, tokens: Int64?) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                        .foregroundStyle(secondaryText)
                Text(tokens.map(compactTokens) ?? "—")
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                Text(tokens.map(estimatedDollars) ?? "$—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(accent)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
    }

    private var quotaSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("额度")
                    .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryText)
                Spacer()
                Text("剩余")
                    .font(.caption2)
                .foregroundStyle(tertiaryText)
            }

            quotaRow(title: "5 小时", minutes: 300)
            Divider().opacity(0.28)
            quotaRow(title: "1 周", minutes: 10_080)
            Divider().opacity(0.28)
            quotaRow(title: "1 月", minutes: 43_200)
        }
        .padding(14)
        .frostedSurface(cornerRadius: 16)
    }

    private func quotaRow(title: String, minutes: Int64) -> some View {
        let window = quotaWindow(minutes: minutes)
        return HStack(spacing: 10) {
            Circle()
                .fill(window == nil ? Color.secondary.opacity(0.35) : accent)
                .frame(width: 7, height: 7)

            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(width: 48, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView(value: Double(window?.remainingPercent ?? 0), total: 100)
                        .tint(accent)
                    Text(window.map { "\($0.remainingPercent)%" } ?? unavailableText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(window == nil ? secondaryText : Color.primary)
                        .frame(width: 64, alignment: .trailing)
                }
                if let resetDate = window?.resetDate {
                    Text("\(resetDate.formatted(.dateTime.month().day().hour().minute())) 刷新")
                        .font(.caption2)
                .foregroundStyle(tertiaryText)
                }
            }
        }
        .frame(minHeight: 36)
    }

    private var primaryActions: some View {
        HStack(spacing: 10) {
            Button { navigate(to: .statusBarDisplay) } label: {
                Label("状态栏显示", systemImage: "rectangle.topthird.inset.filled")
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FrostedActionButtonStyle())

            Button { navigate(to: .about) } label: {
                Label("关于", systemImage: "info.circle")
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FrostedActionButtonStyle())
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock")
            Text(store.lastUpdated.map { "更新于 \($0.formatted(.dateTime.hour().minute().second()))" } ?? "等待首次更新")
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                Label("退出", systemImage: "power")
                    .padding(.horizontal, 8)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("退出 Codex Quota")
        }
        .font(.caption2)
                .foregroundStyle(tertiaryText)
        .padding(.leading, 4)
    }

    private var selectedAppearance: InterfaceAppearance {
        InterfaceAppearance(rawValue: interfaceAppearance) ?? .system
    }

    private var secondaryText: Color {
        colorScheme == .dark ? .white.opacity(0.76) : .secondary
    }

    private var tertiaryText: Color {
        colorScheme == .dark ? .white.opacity(0.58) : .secondary.opacity(0.72)
    }

    private var pageTitle: String {
        switch page {
        case .overview: "Codex Quota"
        case .statusBarDisplay: "设置"
        case .customLabels: "自定义文字"
        case .about: "关于"
        }
    }

    private var preferredHeight: CGFloat {
        switch page {
        case .overview: 620
        case .statusBarDisplay: 470
        case .customLabels: 500
        case .about: 470
        }
    }

    private func navigate(to destination: QuotaMenuPage) {
        page = destination
    }

    private func navigateBack() {
        navigate(to: page == .customLabels ? .statusBarDisplay : .overview)
    }

    private var unavailableText: String {
        store.isRefreshing ? "读取中" : "暂无"
    }

    private func quotaWindow(minutes: Int64) -> RateLimitWindow? {
        guard let snapshot = store.snapshot else { return nil }
        return [snapshot.primary, snapshot.secondary]
            .compactMap { $0 }
            .first { $0.windowDurationMins == minutes }
    }

    private func formattedTokens(_ tokens: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
    }

    private func compactTokens(_ tokens: Int64) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    private func estimatedDollars(_ tokens: Int64) -> String {
        let value = Double(tokens) / 1_000_000 * 7.875
        return String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private struct FrostedIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }

    private var borderColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .white.opacity(0.7)
    }
}

private struct FrostedActionButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .background(
                configuration.isPressed ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }

    private var borderColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .white.opacity(0.72)
    }
}

extension View {
    func frostedSurface(cornerRadius: CGFloat, shadow: Bool = true) -> some View {
        modifier(FrostedSurfaceModifier(cornerRadius: cornerRadius, showsShadow: shadow))
    }
}

private struct FrostedSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let showsShadow: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.8)
            }
            .shadow(
                color: showsShadow ? .black.opacity(colorScheme == .dark ? 0.22 : 0.09) : .clear,
                radius: showsShadow ? 10 : 0,
                y: showsShadow ? 4 : 0
            )
    }

    private var borderColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .white.opacity(0.72)
    }
}

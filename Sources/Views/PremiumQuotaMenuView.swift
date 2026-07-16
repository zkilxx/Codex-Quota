import AppKit
import SwiftUI

enum UsagePeriod: String, CaseIterable, Identifiable {
    case today
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今日"
        case .month: "本月"
        case .year: "本年"
        }
    }

    @MainActor
    func tokens(in store: QuotaStore) -> Int64? {
        switch self {
        case .today: store.todayTokens
        case .month: store.monthTokens
        case .year: store.yearTokens
        }
    }

    @MainActor
    func history(in store: QuotaStore) -> [UsageSample] {
        switch self {
        case .today: store.todayHistory
        case .month: store.monthHistory
        case .year: store.yearHistory
        }
    }

    var startDate: Date {
        let calendar = Calendar.current
        switch self {
        case .today:
            return calendar.startOfDay(for: .now)
        case .month:
            return calendar.dateInterval(of: .month, for: .now)?.start ?? .now
        case .year:
            return calendar.dateInterval(of: .year, for: .now)?.start ?? .now
        }
    }

    var endDate: Date {
        let calendar = Calendar.current
        switch self {
        case .today:
            return calendar.date(byAdding: .day, value: 1, to: startDate) ?? .now
        case .month:
            return calendar.date(byAdding: .month, value: 1, to: startDate) ?? .now
        case .year:
            return calendar.date(byAdding: .year, value: 1, to: startDate) ?? .now
        }
    }

    var axisTicks: [UsageAxisTick] {
        let calendar = Calendar.current
        switch self {
        case .today:
            return [0, 6, 12, 18, 24].compactMap { hour in
                calendar.date(byAdding: .hour, value: hour, to: startDate).map {
                    UsageAxisTick(date: $0, label: String(format: "%02d:00", hour))
                }
            }
        case .month:
            let dayCount = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 30
            return [0, dayCount / 4, dayCount / 2, dayCount * 3 / 4, dayCount].compactMap { day in
                calendar.date(byAdding: .day, value: day, to: startDate).map {
                    let label = day == dayCount
                        ? "月末"
                        : "\(calendar.component(.day, from: $0))日"
                    return UsageAxisTick(date: $0, label: label)
                }
            }
        case .year:
            return [(0, "1 月"), (3, "4 月"), (6, "7 月"), (9, "10 月"), (12, "年末")].compactMap { month, label in
                calendar.date(byAdding: .month, value: month, to: startDate).map {
                    UsageAxisTick(date: $0, label: label)
                }
            }
        }
    }
}

struct UsageAxisTick: Identifiable {
    var id: Date { date }
    let date: Date
    let label: String
}

private enum UsageChartLayout {
    static let leadingInset: CGFloat = 20
    static let trailingInset: CGFloat = 20
}

struct PremiumQuotaMenuView: View {
    let store: QuotaStore
    let onClose: () -> Void
    let onPreferredHeightChange: (CGFloat) -> Void

    @State private var page: QuotaMenuPage
    @State private var selectedPeriod = UsagePeriod.today
    @State private var chartRedrawID = 0
    @State private var refreshCompleted = false
    @State private var panelDarkAmount: Double
    @Namespace private var periodSelectionAnimation
    @AppStorage("interfaceAppearance") private var interfaceAppearance = InterfaceAppearance.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private let accent = Color(red: 0.04, green: 0.67, blue: 0.46)
    private let ink = Color(red: 0.04, green: 0.12, blue: 0.24)

    init(
        store: QuotaStore,
        initialPage: QuotaMenuPage = .overview,
        initialPeriod: UsagePeriod = .today,
        onClose: @escaping () -> Void = {},
        onPreferredHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.store = store
        self.onClose = onClose
        self.onPreferredHeightChange = onPreferredHeightChange
        _page = State(initialValue: initialPage)
        _selectedPeriod = State(initialValue: initialPeriod)
        _panelDarkAmount = State(initialValue: Self.initialDarkAmount())
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 62)
                    .accessibilityHidden(true)
                Divider().opacity(0.34)
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            header
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            panelTint.ignoresSafeArea()
        }
        .tint(accent)
        .foregroundStyle(primaryText)
        .preferredColorScheme(selectedAppearance.colorScheme)
        .onAppear {
            panelDarkAmount = colorScheme == .dark ? 1 : 0
            onPreferredHeightChange(preferredHeight)
        }
        .onChange(of: colorScheme) { _, newScheme in
            // NSAppearance redraws materials immediately. Keep the custom 80% tint
            // in the same frame so the two palettes never blend into a muddy midpoint.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                panelDarkAmount = newScheme == .dark ? 1 : 0
            }
        }
        .onChange(of: page) { _, _ in onPreferredHeightChange(preferredHeight) }
        .onChange(of: store.isRefreshing) { wasRefreshing, isRefreshing in
            guard wasRefreshing, !isRefreshing, store.errorMessage == nil else { return }
            refreshCompleted = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                refreshCompleted = false
            }
        }
    }

    private var panelTint: some View {
        Color(
            red: mix(1.0, 0.025),
            green: mix(1.0, 0.055),
            blue: mix(1.0, 0.085)
        )
        .opacity(0.80)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .overview:
            overview.transition(.opacity)
        case .statusBarDisplay:
            SettingsView(
                onEditLabels: { navigate(to: .customLabels) },
                themeDarkAmount: panelDarkAmount
            )
                .padding(.horizontal, PanelLayoutMetrics.horizontalInset)
                .padding(.top, PanelLayoutMetrics.topInset)
                .padding(.bottom, PanelLayoutMetrics.bottomInset)
                .transition(.opacity)
        case .customLabels:
            CustomLabelsView()
                .padding(.horizontal, PanelLayoutMetrics.horizontalInset)
                .padding(.top, PanelLayoutMetrics.topInset)
                .padding(.bottom, PanelLayoutMetrics.bottomInset)
                .transition(.opacity)
        case .about:
            AboutView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Image(nsImage: Self.chatGPTLogo)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .opacity(page == .overview ? 1 : 0)
                    .scaleEffect(page == .overview ? 1 : 0.88)

                Button { navigateBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PremiumIconButtonStyle())
                .help("返回")
                .opacity(page == .overview ? 0 : 1)
                .scaleEffect(page == .overview ? 0.88 : 1)
                .allowsHitTesting(page != .overview)
            }
            .frame(width: 34, height: 34)

            Text(pageTitle)
                .font(.system(size: 18, weight: .semibold))
                .tracking(-0.25)
                .frame(height: 34, alignment: .center)
                .contentTransition(.interpolate)

            Spacer()

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.errorMessage == nil ? accent : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(store.errorMessage == nil ? "实时" : "需检查")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(secondaryText)
                }

                refreshControl
            }
            .frame(width: 132, alignment: .trailing)
            .opacity(page == .overview ? 1 : 0)
            .allowsHitTesting(page == .overview)
        }
        .padding(.horizontal, PanelLayoutMetrics.horizontalInset)
        .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .center)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .animation(nil, value: page)
    }

    private var refreshControl: some View {
        Button { store.refresh() } label: {
            Group {
                if store.isRefreshing {
                    HStack(spacing: 7) {
                        Text("同步中")
                        SyncDots(accent: accent)
                    }
                } else if refreshCompleted {
                    Label("已更新", systemImage: "checkmark")
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .font(.caption.weight(.semibold))
            .frame(width: 72, height: 31)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PremiumIconButtonStyle())
        .disabled(store.isRefreshing)
        .help("立即刷新")
        .keyboardShortcut("r")
        .animation(.easeInOut(duration: 0.18), value: store.isRefreshing)
        .animation(.easeInOut(duration: 0.18), value: refreshCompleted)
    }

    private var overview: some View {
        VStack(spacing: 0) {
            hero
            periodPicker
                .padding(.top, 7)
            quotaSummary
                .padding(.top, 13)
            Spacer(minLength: 8)
            primaryActions
            footer
        }
        .padding(.horizontal, PanelLayoutMetrics.horizontalInset)
        .padding(.top, PanelLayoutMetrics.topInset)
        .padding(.bottom, PanelLayoutMetrics.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(selectedPeriod.title) Token")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryText)
                    .contentTransition(.interpolate)
                Spacer()
                Text(selectedTokens.map { "≈ \(estimatedDollars($0))" } ?? "≈ $—")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(accent)
                    .contentTransition(.numericText(value: Double(selectedTokens ?? 0)))
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(tertiaryText)
                    .help("按模拟单价换算，并非实际账单")
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(selectedTokens.map(compactHeroTokens) ?? "—")
                    .font(.system(size: 48, weight: .medium).monospacedDigit())
                    .tracking(-1.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentTransition(.numericText(value: Double(selectedTokens ?? 0)))
                Text("Token")
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                Spacer(minLength: 0)
            }

            ZStack { periodChart }
            .frame(height: 108)
            .clipped()
            .accessibilityLabel("\(selectedPeriod.title)分时 Token 用量")

            GeometryReader { proxy in
                ForEach(selectedPeriod.axisTicks) { tick in
                    Text(tick.label)
                        .frame(width: 40)
                        .position(
                            x: axisXPosition(for: tick.date, period: selectedPeriod, width: proxy.size.width),
                            y: proxy.size.height / 2
                        )
                }
            }
            .frame(height: 12)
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(tertiaryText)
            .contentTransition(.interpolate)
            .animation(.smooth(duration: 0.42), value: selectedPeriod)
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(UsagePeriod.allCases) { period in
                Button {
                    selectPeriod(period)
                } label: {
                    Text(period.title)
                        .font(.subheadline.weight(selectedPeriod == period ? .semibold : .regular))
                        .foregroundStyle(selectedPeriod == period ? accent : secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if selectedPeriod == period {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selectedSegmentFill)
                                    .matchedGeometryEffect(id: "period-selection", in: periodSelectionAnimation)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(surfaceBorder, lineWidth: 0.7)
        }
    }

    private var selectedSegmentFill: Color {
        Color(
            red: mix(0.98, 0.20),
            green: mix(0.99, 0.21),
            blue: mix(1.00, 0.22)
        )
    }

    private var quotaSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("额度余量")
                .font(.caption.weight(.semibold))
                .foregroundStyle(secondaryText)
                .padding(.bottom, 7)

            quotaRow(title: "5 小时额度", symbol: "timer", minutes: 300)
            Divider().opacity(0.27).padding(.leading, 36)
            quotaRow(title: "1 周额度", symbol: "calendar", minutes: 10_080)
            Divider().opacity(0.27).padding(.leading, 36)
            quotaRow(title: "1 月额度", symbol: "calendar.badge.clock", minutes: 43_200)
        }
    }

    private func quotaRow(title: String, symbol: String, minutes: Int64) -> some View {
        let window = quotaWindow(minutes: minutes)
        let remaining = window?.remainingPercent ?? 0

        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(window == nil ? tertiaryText : accent)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(resetDescription(for: window))
                    .font(.system(size: 10))
                    .foregroundStyle(tertiaryText)
            }
            .frame(width: 100, alignment: .leading)

            ProgressView(value: Double(remaining), total: 100)
                .progressViewStyle(.linear)
                .tint(accent)

            Text(window.map { "\($0.remainingPercent)%" } ?? unavailableText)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(window == nil ? tertiaryText : accent)
                .frame(width: 45, alignment: .trailing)
        }
        .frame(height: 42)
    }

    private var primaryActions: some View {
        HStack(spacing: 10) {
            Button { navigate(to: .statusBarDisplay) } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PremiumActionButtonStyle(fill: selectedSegmentFill, border: surfaceBorder))

            Button { navigate(to: .about) } label: {
                Label("关于", systemImage: "info.circle")
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PremiumActionButtonStyle(fill: selectedSegmentFill, border: surfaceBorder))
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
            Text(store.lastUpdated.map { "最后更新：\($0.formatted(.dateTime.hour().minute().second()))" } ?? "等待首次更新")
            Spacer()
            if store.errorMessage == nil, store.lastUpdated != nil {
                Image(systemName: "checkmark.circle")
                Text("已是最新")
            }
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("退出 Codex Quota")
        }
        .font(.system(size: 9))
        .foregroundStyle(tertiaryText)
        .padding(.top, 10)
    }

    private var selectedTokens: Int64? { selectedPeriod.tokens(in: store) }

    private var selectedHistory: [UsageSample] { selectedPeriod.history(in: store) }

    @ViewBuilder
    private var periodChart: some View {
        switch selectedPeriod {
        case .today:
            trendChart(for: .today)
        case .month:
            trendChart(for: .month)
        case .year:
            trendChart(for: .year)
        }
    }

    private func trendChart(for period: UsagePeriod) -> some View {
        UsageTrendView(
            period: period,
            samples: period.history(in: store),
            accent: accent,
            redrawID: chartRedrawID
        )
            .id(period)
            .transition(.identity)
    }

    private func selectPeriod(_ period: UsagePeriod) {
        guard period != selectedPeriod else { return }
        chartRedrawID += 1
        withAnimation(.smooth(duration: 0.32)) { selectedPeriod = period }
    }

    private func axisXPosition(for date: Date, period: UsagePeriod, width: CGFloat) -> CGFloat {
        let duration = max(1, period.endDate.timeIntervalSince(period.startDate))
        let fraction = min(1, max(0, date.timeIntervalSince(period.startDate) / duration))
        return UsageChartLayout.leadingInset
            + (width - UsageChartLayout.leadingInset - UsageChartLayout.trailingInset) * fraction
    }

    private static let chatGPTLogo: NSImage = {
        let paths = [
            "/Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.png",
            "/Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.icns"
        ]
        return paths.compactMap(NSImage.init(contentsOfFile:)).first
            ?? NSApp.applicationIconImage
    }()

    private var selectedAppearance: InterfaceAppearance {
        InterfaceAppearance(rawValue: interfaceAppearance) ?? .system
    }

    private var primaryText: Color {
        Color(
            red: mix(0.04, 0.94),
            green: mix(0.12, 0.94),
            blue: mix(0.24, 0.94)
        )
    }

    private var secondaryText: Color {
        Color(
            red: mix(0.405, 0.68),
            green: mix(0.454, 0.68),
            blue: mix(0.529, 0.68)
        )
    }

    private var tertiaryText: Color {
        Color(
            red: mix(0.558, 0.48),
            green: mix(0.595, 0.48),
            blue: mix(0.650, 0.48)
        )
    }

    private var surfaceBorder: Color {
        Color.white.opacity(mix(0.10, 0.11))
    }

    private func mix(_ light: Double, _ dark: Double) -> Double {
        light + (dark - light) * panelDarkAmount
    }

    private static func initialDarkAmount() -> Double {
        let preference = UserDefaults.standard.string(forKey: "interfaceAppearance") ?? "system"
        if preference == "dark" { return 1 }
        if preference == "light" { return 0 }
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? 1 : 0
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
        case .overview: 600
        case .statusBarDisplay: 570
        case .customLabels: 520
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

    private func resetDescription(for window: RateLimitWindow?) -> String {
        guard let resetDate = window?.resetDate else { return store.isRefreshing ? "正在读取" : "暂未提供" }
        return "重置于 \(resetDate.formatted(.dateTime.month().day().hour().minute()))"
    }

    private func compactHeroTokens(_ tokens: Int64) -> String {
        if tokens >= 1_000_000_000 { return String(format: "%.2fB", Double(tokens) / 1_000_000_000) }
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    private func estimatedDollars(_ tokens: Int64) -> String {
        let value = Double(tokens) / 1_000_000 * 7.875
        return String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private struct UsageTrendView: View {
    let period: UsagePeriod
    let samples: [UsageSample]
    let accent: Color
    let redrawID: Int

    @State private var hoverLocation: CGPoint?
    @State private var animationStart: Date
    @State private var animationFinished: Bool

    private let animationDuration: TimeInterval = 1.25

    init(period: UsagePeriod, samples: [UsageSample], accent: Color, redrawID: Int) {
        self.period = period
        self.samples = samples
        self.accent = accent
        self.redrawID = redrawID
        _animationStart = State(initialValue: .now)
        _animationFinished = State(initialValue: CommandLine.arguments.contains("--render-snapshot"))
    }

    private struct PlottedPoint {
        let sample: UsageSample
        let point: CGPoint
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: animationFinished)) { timeline in
            GeometryReader { proxy in
                let plotted = plottedPoints(in: proxy.size)
                let hovered = nearestPoint(to: hoverLocation, in: plotted)
                let drawProgress = animationProgress(at: timeline.date)

                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let baseline = size.height - 6
                        let guideColor = Color.secondary.opacity(0.12)
                        for fraction in [0.0, 0.5, 1.0] {
                            let y = baseline * fraction
                            var guide = Path()
                            guide.move(to: CGPoint(x: UsageChartLayout.leadingInset, y: y))
                            guide.addLine(to: CGPoint(x: size.width - UsageChartLayout.trailingInset, y: y))
                            context.stroke(guide, with: .color(guideColor), lineWidth: 0.5)
                        }

                        let points = plotted.map(\.point)
                        guard !points.isEmpty else { return }
                        if points.count >= 2 {
                            let line = smoothPath(through: points)
                            let revealedLine = line.trimmedPath(from: 0, to: max(0.001, drawProgress))
                            var area = revealedLine
                            let currentPoint = revealedLine.currentPoint ?? points[0]
                            area.addLine(to: CGPoint(x: currentPoint.x, y: baseline))
                            area.addLine(to: CGPoint(x: points.first?.x ?? 0, y: baseline))
                            area.closeSubpath()
                            context.fill(area, with: .color(accent.opacity(0.10)))
                            context.stroke(revealedLine, with: .color(accent.opacity(0.88)), lineWidth: 1.7)

                            if drawProgress > 0.01 {
                                context.fill(
                                    Path(ellipseIn: CGRect(x: currentPoint.x - 3.5, y: currentPoint.y - 3.5, width: 7, height: 7)),
                                    with: .color(accent)
                                )
                                context.stroke(
                                    Path(ellipseIn: CGRect(x: currentPoint.x - 5.5, y: currentPoint.y - 5.5, width: 11, height: 11)),
                                    with: .color(accent.opacity(0.24)),
                                    lineWidth: 2
                                )
                            }
                        }

                        if points.count == 1, let last = points.last {
                            context.fill(
                                Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)),
                                with: .color(accent)
                            )
                            context.stroke(
                                Path(ellipseIn: CGRect(x: last.x - 5.5, y: last.y - 5.5, width: 11, height: 11)),
                                with: .color(accent.opacity(0.24)),
                                lineWidth: 2
                            )
                        }

                        if let hovered {
                            var guide = Path()
                            guide.move(to: CGPoint(x: hovered.point.x, y: 3))
                            guide.addLine(to: CGPoint(x: hovered.point.x, y: baseline))
                            context.stroke(
                                guide,
                                with: .color(accent.opacity(0.28)),
                                style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])
                            )
                            context.fill(
                                Path(ellipseIn: CGRect(x: hovered.point.x - 4, y: hovered.point.y - 4, width: 8, height: 8)),
                                with: .color(accent)
                            )
                        }
                    }

                    if samples.isEmpty {
                        Text("暂无历史数据")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(
                                width: proxy.size.width - UsageChartLayout.leadingInset - UsageChartLayout.trailingInset,
                                height: proxy.size.height
                            )
                            .offset(x: UsageChartLayout.leadingInset)
                    }

                    if let hovered {
                        hoverCard(for: hovered.sample)
                            .position(
                                x: min(max(hovered.point.x, 58), proxy.size.width - UsageChartLayout.trailingInset - 38),
                                y: max(20, hovered.point.y - 24)
                            )
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverLocation = location
                    case .ended:
                        withAnimation(.easeOut(duration: 0.12)) { hoverLocation = nil }
                    }
                }
            }
        }
        .task(id: redrawID) {
            guard !CommandLine.arguments.contains("--render-snapshot") else { return }
            animationStart = .now
            animationFinished = false
            try? await Task.sleep(for: .seconds(animationDuration))
            animationFinished = true
        }
    }

    private func animationProgress(at date: Date) -> CGFloat {
        guard !CommandLine.arguments.contains("--render-snapshot") else { return 1 }
        let linear = min(1, max(0, date.timeIntervalSince(animationStart) / animationDuration))
        return CGFloat(linear * linear * (3 - 2 * linear))
    }

    private func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let horizontalControl = max(0, current.x - previous.x) * 0.38
            path.addCurve(
                to: current,
                control1: CGPoint(x: previous.x + horizontalControl, y: previous.y),
                control2: CGPoint(x: current.x - horizontalControl, y: current.y)
            )
        }
        return path
    }

    private func plottedPoints(in size: CGSize) -> [PlottedPoint] {
        let start = period.startDate
        let end = period.endDate
        let duration = max(1, end.timeIntervalSince(start))
        let history = samples
        let maximum = max(1, history.map(\.tokens).max() ?? 1)
        let baseline = size.height - 6
        let plotWidth = max(1, size.width - UsageChartLayout.leadingInset - UsageChartLayout.trailingInset)

        return history.map { sample in
            let xFraction = min(1, max(0, sample.date.timeIntervalSince(start) / duration))
            let yFraction = Double(sample.tokens) / Double(maximum)
            return PlottedPoint(
                sample: sample,
                point: CGPoint(
                    x: UsageChartLayout.leadingInset + plotWidth * xFraction,
                    y: min(baseline - 6, max(6, baseline * CGFloat(1 - yFraction)))
                )
            )
        }
    }

    private func nearestPoint(to location: CGPoint?, in points: [PlottedPoint]) -> PlottedPoint? {
        guard let location, !points.isEmpty else { return nil }
        return points.min { abs($0.point.x - location.x) < abs($1.point.x - location.x) }
    }

    private func hoverCard(for sample: UsageSample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hoverDate(sample.date))
                .foregroundStyle(.secondary)
            Text(compactTokens(sample.tokens))
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.system(size: 9))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }

    private func hoverDate(_ date: Date) -> String {
        switch period {
        case .today: date.formatted(.dateTime.hour().minute())
        case .month: date.formatted(.dateTime.month().day())
        case .year: date.formatted(.dateTime.year().month())
        }
    }

    private func compactTokens(_ tokens: Int64) -> String {
        if tokens >= 1_000_000_000 { return String(format: "%.2fB Token", Double(tokens) / 1_000_000_000) }
        if tokens >= 1_000_000 { return String(format: "%.1fM Token", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK Token", Double(tokens) / 1_000) }
        return "\(tokens) Token"
    }

}

private struct SyncDots: View {
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.32)) { timeline in
            let phase = Int(timeline.date.timeIntervalSinceReferenceDate / 0.32) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(accent)
                        .frame(width: 3.5, height: 3.5)
                        .opacity(index == phase ? 1 : 0.28)
                }
            }
        }
    }
}

private struct PremiumIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.08), lineWidth: 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .opacity(configuration.isPressed ? 0.68 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct PremiumActionButtonStyle: ButtonStyle {
    let fill: Color
    let border: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .background(
                configuration.isPressed ? fill.opacity(0.78) : fill,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

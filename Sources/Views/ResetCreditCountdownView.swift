import SwiftUI

struct ResetCreditCountdownView: View {
    let summary: RateLimitResetCreditsSummary?
    let isRefreshing: Bool
    let accent: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = timeline.date
            let cards = summary?.availableFullResetCredits(at: now) ?? []
            let availableCount = summary?.effectiveAvailableCount(at: now)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("完全重置卡")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryText)
                    Spacer()
                    if let availableCount {
                        Text("\(availableCount) 张可用")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(availableCount > 0 ? accent : tertiaryText)
                    }
                }

                if summary == nil {
                    emptyText(isRefreshing ? "正在读取重置卡…" : "暂未提供重置卡信息")
                } else if availableCount == 0 {
                    emptyText("暂无可用完全重置卡")
                } else {
                    ForEach(cards) { card in
                        cardRow(card, now: now)
                    }
                    let missingCount = max(0, (availableCount ?? 0) - Int64(cards.count))
                    if missingCount > 0 {
                        emptyText("另有 \(missingCount) 张卡暂未提供到期明细")
                    }
                }
            }
        }
    }

    private func cardRow(_ card: RateLimitResetCredit, now: Date) -> some View {
        let expiration = ResetCreditCountdownFormatter.expirationText(for: card.expirationDate, now: now)
        let countdown = ResetCreditCountdownFormatter.remainingText(until: card.expirationDate, now: now)
        let isUrgent = ResetCreditCountdownFormatter.isExpiringSoon(until: card.expirationDate, now: now)
        let color = isUrgent ? Color.orange : accent

        return HStack(spacing: 9) {
            Image(systemName: isUrgent ? "ticket.fill" : "ticket")
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 26)
            Text(expiration)
                .font(.system(size: 11))
                .foregroundStyle(primaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(countdown)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: 26)
        .help(isUrgent ? "24 小时内到期，剩余 \(countdown)" : "剩余有效时间：\(countdown)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("完全重置卡，\(expiration)，\(countdown)")
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(tertiaryText)
            .padding(.vertical, 4)
    }
}

import Testing
@testable import CodexQuota

@Test func firstFetchIncludesLocalUsageWhileServerTodayIsDelayed() {
    let server = TokenUsageReconciler.Totals(today: 0, month: 1_000, year: 2_000)
    let result = TokenUsageReconciler.reconcile(
        server: server,
        baseline: server,
        localTodayTokens: 250,
        localBaseline: 250
    )

    #expect(result == .init(today: 250, month: 1_250, year: 2_250))
}

@Test func delayedServerCatchUpDoesNotDoubleCountLocalUsage() {
    let baseline = TokenUsageReconciler.Totals(today: 0, month: 1_000, year: 2_000)
    let partiallyCaughtUp = TokenUsageReconciler.reconcile(
        server: .init(today: 100, month: 1_100, year: 2_100),
        baseline: baseline,
        localTodayTokens: 250,
        localBaseline: 250
    )
    let caughtUp = TokenUsageReconciler.reconcile(
        server: .init(today: 250, month: 1_250, year: 2_250),
        baseline: baseline,
        localTodayTokens: 250,
        localBaseline: 250
    )

    #expect(partiallyCaughtUp == .init(today: 250, month: 1_250, year: 2_250))
    #expect(caughtUp == partiallyCaughtUp)
}

@Test func existingBaselineDeltaRemainsAMonotonicFloor() {
    let result = TokenUsageReconciler.reconcile(
        server: .init(today: 80, month: 950, year: 4_900),
        baseline: .init(today: 100, month: 1_000, year: 5_000),
        localTodayTokens: 80,
        localBaseline: 20
    )

    #expect(result == .init(today: 160, month: 1_060, year: 5_060))
}

@Test func largerAccountUsageWinsWithoutAddingLocalUsageAgain() {
    let server = TokenUsageReconciler.Totals(today: 500, month: 2_000, year: 10_000)
    let result = TokenUsageReconciler.reconcile(
        server: server,
        baseline: .init(today: 100, month: 1_000, year: 5_000),
        localTodayTokens: 250,
        localBaseline: 250
    )

    #expect(result == server)
}

@Test func noLocalUsageLeavesAccountTotalsUnchanged() {
    let server = TokenUsageReconciler.Totals(today: 40, month: 500, year: 800)
    let result = TokenUsageReconciler.reconcile(
        server: server,
        baseline: server,
        localTodayTokens: 0,
        localBaseline: 0
    )

    #expect(result == server)
}

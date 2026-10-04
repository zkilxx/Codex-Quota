enum TokenUsageReconciler {
    struct Totals: Equatable, Sendable {
        let today: Int64
        let month: Int64
        let year: Int64
    }

    static func reconcile(
        server: Totals,
        baseline: Totals,
        localTodayTokens: Int64,
        localBaseline: Int64
    ) -> Totals {
        let localDelta = max(0, localTodayTokens - localBaseline)
        let today = max(localTodayTokens, max(server.today, baseline.today + localDelta))
        let missingToday = max(0, today - server.today)
        return Totals(
            today: today,
            month: max(server.month + missingToday, baseline.month + localDelta),
            year: max(server.year + missingToday, baseline.year + localDelta)
        )
    }
}

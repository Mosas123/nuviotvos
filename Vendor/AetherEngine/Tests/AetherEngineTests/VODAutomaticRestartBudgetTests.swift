import Foundation
import Testing
@testable import AetherEngine

@Suite("VOD automatic restart budget")
struct VODAutomaticRestartBudgetTests {
    @Test("the first restart is immediate and the next waits from replacement start")
    func graceStartsAfterReplacementWork() {
        var budget = VODAutomaticRestartBudget()

        #expect(budget.admit(now: 10, renderedPosition: 50)
            == .restart(attempt: 1, elapsed: 0, remaining: 120, progressReset: false))
        budget.markReplacementStarted(at: 35) // 25 seconds spent stopping/reopening the old source.
        #expect(budget.admit(now: 64, renderedPosition: 50)
            == .deferred(remaining: 1, shouldLog: true))
        #expect(budget.admit(now: 65, renderedPosition: 50)
            == .restart(attempt: 2, elapsed: 55, remaining: 65, progressReset: false))
    }

    @Test("an authoritative VOD replacement also gives the fresh reader its grace")
    func authoritativeReplacementAnchorsNextAutomaticGrace() {
        var budget = VODAutomaticRestartBudget()
        admitAndFinish(&budget, at: 0, position: 250)

        budget.markReplacementStarted(at: 40) // authoritative recovery bypassed the automatic budget.
        #expect(budget.admit(now: 41, renderedPosition: 250)
            == .deferred(remaining: 29, shouldLog: true))
        #expect(budget.admit(now: 70, renderedPosition: 250)
            == .restart(attempt: 2, elapsed: 70, remaining: 50, progressReset: false))
    }

    @Test("the third admitted replacement gets its cooldown before count exhaustion")
    func thirdReplacementGracePrecedesExhaustion() {
        var budget = VODAutomaticRestartBudget()
        admitAndFinish(&budget, at: 0, position: 252)
        admitAndFinish(&budget, at: 30, position: 252)
        admitAndFinish(&budget, at: 75, position: 252)

        #expect(budget.admit(now: 76, renderedPosition: 252)
            == .deferred(remaining: 59, shouldLog: true))
        #expect(budget.admit(now: 120, renderedPosition: 252)
            == .exhausted(firstReport: true, attempts: 3, elapsed: 120))
        #expect(budget.admit(now: 121, renderedPosition: 252)
            == .exhausted(firstReport: false, attempts: 3, elapsed: 121))
    }

    @Test("no replacement starts when the episode cannot provide a full fresh-reader grace")
    func lateAdmissionDefersToEpisodeDeadline() {
        var budget = VODAutomaticRestartBudget()
        admitAndFinish(&budget, at: 0, position: 40)
        admitAndFinish(&budget, at: 30, position: 40)

        #expect(budget.admit(now: 91, renderedPosition: 40)
            == .deferred(remaining: 29, shouldLog: true))
        #expect(budget.admit(now: 120, renderedPosition: 40)
            == .exhausted(firstReport: true, attempts: 2, elapsed: 120))
    }

    @Test("replayed lower output does not renew the episode, but real rendered progress does")
    func onlyNewMaximumRenderedProgressResetsBudget() {
        var budget = VODAutomaticRestartBudget()
        admitAndFinish(&budget, at: 0, position: 252)
        #expect(budget.admit(now: 30, renderedPosition: 250)
            == .restart(attempt: 2, elapsed: 30, remaining: 90, progressReset: false))
        budget.markReplacementStarted(at: 30)
        #expect(budget.admit(now: 75, renderedPosition: 252.4)
            == .restart(attempt: 3, elapsed: 75, remaining: 45, progressReset: false))
        budget.markReplacementStarted(at: 75)

        #expect(budget.admit(now: 80, renderedPosition: 252.51)
            == .restart(attempt: 1, elapsed: 0, remaining: 120, progressReset: true))
    }

    @Test("an explicit backward seek starts a fresh progress baseline")
    func backwardUserSeekResetsBudgetBaseline() {
        var budget = VODAutomaticRestartBudget()
        admitAndFinish(&budget, at: 0, position: 252)
        admitAndFinish(&budget, at: 30, position: 252)
        admitAndFinish(&budget, at: 75, position: 252)
        #expect(budget.admit(now: 120, renderedPosition: 252)
            == .exhausted(firstReport: true, attempts: 3, elapsed: 120))

        budget.resetForUserSeek()
        #expect(budget.admit(now: 200, renderedPosition: 50)
            == .restart(attempt: 1, elapsed: 0, remaining: 120, progressReset: false))
        budget.markReplacementStarted(at: 200)
        #expect(budget.admit(now: 230, renderedPosition: 50.51)
            == .restart(attempt: 1, elapsed: 0, remaining: 120, progressReset: true))
    }

    @Test("deferred diagnostics are rate limited")
    func deferredLogsAreRateLimited() {
        var budget = VODAutomaticRestartBudget()
        admitAndFinish(&budget, at: 0, position: 10)
        #expect(budget.admit(now: 1, renderedPosition: 10)
            == .deferred(remaining: 29, shouldLog: true))
        #expect(budget.admit(now: 2, renderedPosition: 10)
            == .deferred(remaining: 28, shouldLog: false))
        #expect(budget.admit(now: 11, renderedPosition: 10)
            == .deferred(remaining: 19, shouldLog: true))
    }

    @Test("a later denied coalesced request preserves the earlier active producer")
    func deniedPendingRequestKeepsEarlierSuccess() {
        var outcome = VODRestartRunOutcome()
        outcome.record(.restarted(at: 44))
        outcome.record(.deferred(remaining: 12))

        #expect(outcome.providerResult == .restarted(at: 44))
    }

    @Test("a later destructive producer-build failure invalidates an earlier success")
    func failedPendingRequestCannotPublishEarlierProducer() {
        var outcome = VODRestartRunOutcome()
        outcome.record(.restarted(at: 44))
        outcome.record(.failed)

        #expect(outcome.providerResult == .failed)
    }

    private func admitAndFinish(_ budget: inout VODAutomaticRestartBudget, at time: TimeInterval, position: Double) {
        if case .restart = budget.admit(now: time, renderedPosition: position) {
            budget.markReplacementStarted(at: time)
        } else {
            Issue.record("Expected an automatic restart admission at \(time)s")
        }
    }
}

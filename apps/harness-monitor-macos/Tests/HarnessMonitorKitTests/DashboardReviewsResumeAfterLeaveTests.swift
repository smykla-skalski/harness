import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews resume-after-leave")
struct DashboardReviewsResumeAfterLeaveTests {
  @Test("leaving the route with in-flight work arms a resume-on-return reload")
  func leavingTheRouteWithInFlightWorkArmsAResumeOnReturnReload() {
    let decision = dashboardReviewsRouteChangeDecision(
      newRoute: .taskBoard,
      wasOnReviews: true,
      hasInFlightWork: true,
      hasPendingResume: false
    )
    #expect(decision == .leave(armPendingResume: true))
  }

  @Test("leaving the route with no in-flight work does not arm a resume reload")
  func leavingTheRouteWithNoInFlightWorkDoesNotArmAResumeReload() {
    let decision = dashboardReviewsRouteChangeDecision(
      newRoute: .taskBoard,
      wasOnReviews: true,
      hasInFlightWork: false,
      hasPendingResume: false
    )
    #expect(decision == .leave(armPendingResume: false))
  }

  @Test("returning to the route with a pending reload schedules a refresh")
  func returningToTheRouteWithAPendingReloadSchedulesARefresh() {
    let decision = dashboardReviewsRouteChangeDecision(
      newRoute: .reviews,
      wasOnReviews: false,
      hasInFlightWork: false,
      hasPendingResume: true
    )
    #expect(decision == .returnToRoute(triggerReload: true))
  }

  @Test("returning to the route without pending work does not trigger a reload")
  func returningToTheRouteWithoutPendingWorkDoesNotTriggerAReload() {
    let decision = dashboardReviewsRouteChangeDecision(
      newRoute: .reviews,
      wasOnReviews: false,
      hasInFlightWork: false,
      hasPendingResume: false
    )
    #expect(decision == .returnToRoute(triggerReload: false))
  }

  @Test("a no-op route change while on reviews does not change state")
  func aNoOpRouteChangeWhileOnReviewsDoesNotChangeState() {
    let decision = dashboardReviewsRouteChangeDecision(
      newRoute: .reviews,
      wasOnReviews: true,
      hasInFlightWork: true,
      hasPendingResume: false
    )
    #expect(decision == .noChange)
  }

  @Test("a no-op route change while elsewhere does not change state")
  func aNoOpRouteChangeWhileElsewhereDoesNotChangeState() {
    let decision = dashboardReviewsRouteChangeDecision(
      newRoute: .diagnostics,
      wasOnReviews: false,
      hasInFlightWork: false,
      hasPendingResume: true
    )
    #expect(decision == .noChange)
  }

  @Test("leaving the route does not cancel in-flight tasks")
  func leavingTheRouteDoesNotCancelInFlightTasks() throws {
    // The previous implementation called cancelAllInFlightTasks() any time
    // the dashboard route picker moved off reviews. The new pause-on-leave
    // policy must NOT do that: tracked refresh and mutation tasks should
    // get to complete so their results are already applied when the user
    // returns. We assert by exercising the pure decision function: every
    // outcome of `leave` is either `armPendingResume: true` or `false` -
    // there is no `cancel` shape in the enum at all.
    let decisionWithWork = dashboardReviewsRouteChangeDecision(
      newRoute: .policyCanvas,
      wasOnReviews: true,
      hasInFlightWork: true,
      hasPendingResume: false
    )
    let decisionWithoutWork = dashboardReviewsRouteChangeDecision(
      newRoute: .policyCanvas,
      wasOnReviews: true,
      hasInFlightWork: false,
      hasPendingResume: false
    )
    // Both decisions are still `.leave` - the resume-arming flag is the only
    // difference. Critically, neither shape says "cancel".
    if case .leave = decisionWithWork {
      // ok
    } else {
      Issue.record("Expected .leave for in-flight case, got \(decisionWithWork)")
    }
    if case .leave = decisionWithoutWork {
      // ok
    } else {
      Issue.record("Expected .leave for no-work case, got \(decisionWithoutWork)")
    }
  }

  @Test("returning twice with a single armed reload only triggers one reload")
  func returningTwiceWithASingleArmedReloadOnlyTriggersOneReload() {
    // Simulate the user flapping the route picker:
    //   reviews -> taskBoard (arms resume)
    //   taskBoard -> reviews (consumes the arm)
    //   reviews -> taskBoard (no in-flight work, no resume arm)
    //   taskBoard -> reviews (no pending, no reload)
    let firstLeave = dashboardReviewsRouteChangeDecision(
      newRoute: .taskBoard,
      wasOnReviews: true,
      hasInFlightWork: true,
      hasPendingResume: false
    )
    #expect(firstLeave == .leave(armPendingResume: true))
    // After consuming the resume on return, hasPendingResume is false.
    let firstReturn = dashboardReviewsRouteChangeDecision(
      newRoute: .reviews,
      wasOnReviews: false,
      hasInFlightWork: false,
      hasPendingResume: true
    )
    #expect(firstReturn == .returnToRoute(triggerReload: true))
    let secondLeave = dashboardReviewsRouteChangeDecision(
      newRoute: .taskBoard,
      wasOnReviews: true,
      hasInFlightWork: false,
      hasPendingResume: false
    )
    #expect(secondLeave == .leave(armPendingResume: false))
    let secondReturn = dashboardReviewsRouteChangeDecision(
      newRoute: .reviews,
      wasOnReviews: false,
      hasInFlightWork: false,
      hasPendingResume: false
    )
    #expect(secondReturn == .returnToRoute(triggerReload: false))
  }
}

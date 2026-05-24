import XCTest

@testable import HarnessMonitorKit

@MainActor
final class PolicyExecutorNotificationTests: XCTestCase {
  func testDecisionNotificationFailureRetriesWithoutRenotifyingStableOpenDecision()
    async throws
  {
    let api = FakeAPIClient()
    let clock = TestClock()
    let store = try DecisionStore.makeInMemory(now: { clock.now() })
    let exec = PolicyExecutor(
      api: api,
      decisions: store,
      audit: InMemoryAuditWriter(),
      clock: clock,
      cooldown: 1
    )
    let action = PolicyAction.queueDecision(
      .init(
        id: "d1",
        severity: .warn,
        ruleID: "r1",
        sessionID: "s1",
        agentID: nil,
        taskID: nil,
        summary: "Needs attention",
        contextJSON: "{}",
        suggestedActionsJSON: "[]"
      )
    )

    api.notificationFailure = HarnessMonitorAPIError.server(code: 500, message: "notify failed")
    let failed = await exec.execute(action)
    let throttledReplay = await exec.execute(action)
    await clock.advance(by: .seconds(2))
    api.notificationFailure = nil
    let retried = await exec.execute(action)
    let stableOpenReplay = await exec.execute(action)

    guard case .failed = failed else {
      XCTFail("first notification should fail")
      return
    }
    guard case .skippedDuplicate = throttledReplay else {
      XCTFail("notification failure should stay throttled")
      return
    }
    guard case .executed = retried else {
      XCTFail("retry should execute")
      return
    }
    guard case .skippedDuplicate = stableOpenReplay else {
      XCTFail("stable open replay should be deduped")
      return
    }
    XCTAssertEqual(api.notifyCalls.map(\.decisionID), ["d1"])
  }
}

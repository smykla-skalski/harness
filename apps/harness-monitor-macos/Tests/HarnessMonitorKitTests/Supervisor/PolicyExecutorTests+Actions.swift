import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
extension PolicyExecutorTests {
  func testNotifyOnlyIsExecutedAndAudited() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .notifyOnly(
        .init(
          ruleID: "daemon-disconnect",
          snapshotID: "s1",
          snapshotHash: "hash-1",
          severity: .warn,
          summary: "daemon down"
        )
      )
    )

    XCTAssertEqual(api.notifyCalls.map(\.summary), ["daemon down"])
    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionExecuted"])
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }

  func testLogEventOnlyRecordsAudit() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .logEvent(
        .init(
          id: "l1",
          ruleID: "policy-gap",
          snapshotID: "s1",
          message: "unknown code"
        )
      )
    )

    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionExecuted"])
    XCTAssertEqual(api.nudgeCalls, [])
    XCTAssertEqual(api.assignCalls, [])
    XCTAssertEqual(api.dropCalls, [])
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }

  func testSuggestConfigChangeIsAuditedOnly() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .suggestConfigChange(
        .init(
          id: "sg1",
          ruleID: "policy-gap",
          proposalJSON: "{}",
          rationale: "observed new pattern"
        )
      )
    )

    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionExecuted"])
    XCTAssertEqual(api.nudgeCalls, [])
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }
}

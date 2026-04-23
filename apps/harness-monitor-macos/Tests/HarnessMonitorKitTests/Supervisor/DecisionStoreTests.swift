import SwiftData
import XCTest

@testable import HarnessMonitorKit

final class DecisionStoreTests: XCTestCase {
  func test_insertAndListOpen() async throws {
    let store = try DecisionStore.makeInMemory()
    try await store.insert(.fixture(id: "d1"))
    let open = try await store.openDecisions()
    XCTAssertEqual(open.count, 1)
    XCTAssertEqual(open.first?.id, "d1")
    XCTAssertEqual(open.first?.statusRaw, "open")
  }

  func test_insertIsIdempotentOnDuplicateID() async throws {
    let store = try DecisionStore.makeInMemory()
    try await store.insert(.fixture(id: "d1", summary: "first"))
    try await store.insert(.fixture(id: "d1", summary: "second-should-not-overwrite"))
    let open = try await store.openDecisions()
    XCTAssertEqual(open.count, 1)
    XCTAssertEqual(open.first?.summary, "first")
  }

  func test_decisionByIDReturnsRowOrNil() async throws {
    let store = try DecisionStore.makeInMemory()
    try await store.insert(.fixture(id: "d1"))
    let found = try await store.decision(id: "d1")
    XCTAssertEqual(found?.id, "d1")
    let missing = try await store.decision(id: "nope")
    XCTAssertNil(missing)
  }

  func test_snoozeMovesOutOfOpen() async throws {
    let store = try DecisionStore.makeInMemory()
    try await store.insert(.fixture(id: "d1"))
    try await store.snooze(id: "d1", until: Date().addingTimeInterval(3600))
    let open = try await store.openDecisions()
    XCTAssertTrue(open.isEmpty)
    let decision = try await store.decision(id: "d1")
    XCTAssertEqual(decision?.statusRaw, "snoozed")
    XCTAssertNotNil(decision?.snoozedUntil)
  }

  func test_snoozeReappearsAfterExpiry() async throws {
    let store = try DecisionStore.makeInMemory()
    try await store.insert(.fixture(id: "d1"))
    // Past snooze — should be treated as open.
    try await store.snooze(id: "d1", until: Date().addingTimeInterval(-1))
    let open = try await store.openDecisions()
    XCTAssertEqual(open.count, 1)
  }

  func test_resolveMovesOutOfOpen() async throws {
    let store = try DecisionStore.makeInMemory()
    try await store.insert(.fixture(id: "d1"))
    try await store.resolve(id: "d1", outcome: DecisionOutcome(chosenActionID: "nudge", note: "ok"))
    let open = try await store.openDecisions()
    XCTAssertTrue(open.isEmpty)
    let decision = try await store.decision(id: "d1")
    XCTAssertEqual(decision?.statusRaw, "resolved")
    XCTAssertNotNil(decision?.resolutionJSON)
  }

  func test_dismissMovesOutOfOpen() async throws {
    let store = try DecisionStore.makeInMemory()
    try await store.insert(.fixture(id: "d1"))
    try await store.dismiss(id: "d1")
    let open = try await store.openDecisions()
    XCTAssertTrue(open.isEmpty)
    let decision = try await store.decision(id: "d1")
    XCTAssertEqual(decision?.statusRaw, "dismissed")
  }

  func test_expireByAgeDropsRows() async throws {
    let store = try DecisionStore.makeInMemory()
    try await store.insert(.fixture(id: "d1"))
    try await store.insert(.fixture(id: "d2"))
    // Expiring rows older than a negative age catches all rows.
    let removed = try await store.expire(beforeAge: -1)
    XCTAssertEqual(removed, 2)
    let open = try await store.openDecisions()
    XCTAssertTrue(open.isEmpty)
  }

  func test_expireIgnoresFreshRows() async throws {
    let store = try DecisionStore.makeInMemory()
    try await store.insert(.fixture(id: "d1"))
    let removed = try await store.expire(beforeAge: 3600)
    XCTAssertEqual(removed, 0)
    let open = try await store.openDecisions()
    XCTAssertEqual(open.count, 1)
  }

  func test_openCountBySeverity() async throws {
    let store = try DecisionStore.makeInMemory()
    try await store.insert(.fixture(id: "d1", severity: .info))
    try await store.insert(.fixture(id: "d2", severity: .needsUser))
    try await store.insert(.fixture(id: "d3", severity: .needsUser))
    try await store.insert(.fixture(id: "d4", severity: .critical))
    try await store.snooze(id: "d1", until: Date().addingTimeInterval(3600))
    let counts = try await store.openCountBySeverity()
    XCTAssertNil(counts[.info], "snoozed row must not appear")
    XCTAssertEqual(counts[.needsUser], 2)
    XCTAssertEqual(counts[.critical], 1)
  }

  func test_streamEmitsOnInsert() async throws {
    let store = try DecisionStore.makeInMemory()
    let expectation = expectation(description: "receives insert event")
    let task = Task {
      for await event in store.events {
        if event.kind == .inserted, event.decisionID == "d1" {
          expectation.fulfill()
          break
        }
      }
    }
    try await store.insert(.fixture(id: "d1"))
    await fulfillment(of: [expectation], timeout: 2.0)
    task.cancel()
  }

  func test_streamEmitsOnSnoozeResolveDismissExpire() async throws {
    let store = try DecisionStore.makeInMemory()
    try await store.insert(.fixture(id: "d1"))
    try await store.insert(.fixture(id: "d2"))
    try await store.insert(.fixture(id: "d3"))
    try await store.insert(.fixture(id: "d4"))

    let collector = EventCollector()
    let expectation = expectation(description: "receives all non-insert events")
    let task = Task {
      for await event in store.events where event.kind != .inserted {
        let total = await collector.append(event.kind)
        if total == 4 {
          expectation.fulfill()
          break
        }
      }
    }

    try await store.snooze(id: "d1", until: Date().addingTimeInterval(60))
    try await store.resolve(id: "d2", outcome: DecisionOutcome(chosenActionID: nil, note: nil))
    try await store.dismiss(id: "d3")
    _ = try await store.expire(beforeAge: -1)

    await fulfillment(of: [expectation], timeout: 2.0)
    task.cancel()
    let kinds = await collector.snapshot()
    XCTAssertEqual(Set(kinds), Set([.snoozed, .resolved, .dismissed, .expired]))
  }
}

private actor EventCollector {
  private var kinds: [DecisionStore.DecisionEvent.Kind] = []

  func append(_ kind: DecisionStore.DecisionEvent.Kind) -> Int {
    kinds.append(kind)
    return kinds.count
  }

  func snapshot() -> [DecisionStore.DecisionEvent.Kind] { kinds }
}

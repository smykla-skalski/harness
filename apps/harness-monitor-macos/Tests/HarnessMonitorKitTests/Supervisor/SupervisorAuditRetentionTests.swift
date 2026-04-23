import SwiftData
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SupervisorAuditRetentionTests: XCTestCase {
  func test_compactOlderThan_deletesEventsOlderThanConfiguredRetention() async throws {
    let container = try makeContainer()
    let now = Date.fixed
    let retention: TimeInterval = 14 * 24 * 60 * 60
    let fresh = now.addingTimeInterval(-60)
    let stale = now.addingTimeInterval(-retention - 60)
    try insertEvent(id: "fresh", createdAt: fresh, into: container)
    try insertEvent(id: "stale", createdAt: stale, into: container)

    let retention1 = SupervisorAuditRetention(container: container, clock: { now })
    let result = try await retention1.compactOlderThan(retention)

    XCTAssertEqual(result.deletedEvents, 1)
    XCTAssertEqual(result.deletedDecisions, 0)
    XCTAssertEqual(result.totalDeleted, 1)
    XCTAssertEqual(try fetchEventIDs(container), ["fresh"])
  }

  func test_compactOlderThan_preservesEventsWithinRetention() async throws {
    let container = try makeContainer()
    let now = Date.fixed
    let retention: TimeInterval = 60 * 60
    try insertEvent(id: "recent", createdAt: now.addingTimeInterval(-30), into: container)
    try insertEvent(
      id: "boundary",
      createdAt: now.addingTimeInterval(-retention + 1),
      into: container
    )

    let retention1 = SupervisorAuditRetention(container: container, clock: { now })
    let result = try await retention1.compactOlderThan(retention)

    XCTAssertEqual(result.totalDeleted, 0)
    XCTAssertEqual(try fetchEventIDs(container).sorted(), ["boundary", "recent"])
  }

  func test_compactOlderThan_deletesStaleDecisionsAlongsideEvents() async throws {
    let container = try makeContainer()
    let now = Date.fixed
    let retention: TimeInterval = 24 * 60 * 60
    try insertEvent(
      id: "stale-event",
      createdAt: now.addingTimeInterval(-retention - 1),
      into: container
    )
    try insertDecision(
      id: "stale-decision",
      createdAt: now.addingTimeInterval(-retention - 1),
      into: container
    )
    try insertDecision(
      id: "fresh-decision",
      createdAt: now.addingTimeInterval(-60),
      into: container
    )

    let retention1 = SupervisorAuditRetention(container: container, clock: { now })
    let result = try await retention1.compactOlderThan(retention)

    XCTAssertEqual(result.deletedEvents, 1)
    XCTAssertEqual(result.deletedDecisions, 1)
    XCTAssertEqual(try fetchDecisionIDs(container), ["fresh-decision"])
    XCTAssertTrue(try fetchEventIDs(container).isEmpty)
  }

  func test_forceCompactionUsesDefaultRetentionWindow() async throws {
    let container = try makeContainer()
    let now = Date.fixed
    try insertEvent(
      id: "stale-event",
      createdAt: now.addingTimeInterval(-SupervisorAuditRetention.defaultRetention - 1),
      into: container
    )

    let retention1 = SupervisorAuditRetention(container: container, clock: { now })
    let result = try await retention1.forceCompaction()

    XCTAssertEqual(result.deletedEvents, 1)
    XCTAssertEqual(result.deletedDecisions, 0)
    XCTAssertTrue(try fetchEventIDs(container).isEmpty)
  }

  func test_defaultRetentionIsFourteenDays() {
    XCTAssertEqual(SupervisorAuditRetention.defaultRetention, 14 * 24 * 60 * 60)
  }

  func test_startBackgroundCompactionRespectsDisabledPreference() throws {
    let container = try makeContainer()
    let retention1 = SupervisorAuditRetention(container: container)
    UserDefaults.standard.set(false, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      )
    }

    retention1.startBackgroundCompaction()

    XCTAssertFalse(retention1.isBackgroundActivityScheduled)
  }

  func test_startBackgroundCompactionSchedulesWhenPreferenceEnabled() throws {
    let container = try makeContainer()
    let retention1 = SupervisorAuditRetention(container: container)
    UserDefaults.standard.set(true, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    defer {
      retention1.stopBackgroundCompaction()
      UserDefaults.standard.removeObject(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      )
    }

    retention1.startBackgroundCompaction()

    XCTAssertTrue(retention1.isBackgroundActivityScheduled)
  }

  func test_stopBackgroundCompactionIsIdempotent() throws {
    let container = try makeContainer()
    let retention1 = SupervisorAuditRetention(container: container)

    retention1.stopBackgroundCompaction()
    retention1.stopBackgroundCompaction()

    XCTAssertFalse(retention1.isBackgroundActivityScheduled)
  }

  func test_schedulerIdentifierIsDistinctFromMainSupervisor() {
    XCTAssertEqual(
      SupervisorAuditRetention.schedulerIdentifier,
      "io.harnessmonitor.supervisor.retention"
    )
    XCTAssertNotEqual(
      SupervisorAuditRetention.schedulerIdentifier,
      "io.harnessmonitor.supervisor"
    )
  }

  private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
      for: SupervisorEvent.self,
      Decision.self,
      PolicyConfigRow.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
  }

  private func insertEvent(id: String, createdAt: Date, into container: ModelContainer) throws {
    let context = container.mainContext
    let event = SupervisorEvent(
      id: id,
      tickID: "tick-\(id)",
      kind: "ruleEvaluated",
      ruleID: "rule-\(id)",
      severity: .info,
      payloadJSON: "{}"
    )
    event.createdAt = createdAt
    context.insert(event)
    try context.save()
  }

  private func insertDecision(id: String, createdAt: Date, into container: ModelContainer) throws {
    let context = container.mainContext
    let decision = Decision(
      id: id,
      severity: .needsUser,
      ruleID: "rule-\(id)",
      sessionID: nil,
      agentID: nil,
      taskID: nil,
      summary: "summary-\(id)",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
    decision.createdAt = createdAt
    context.insert(decision)
    try context.save()
  }

  private func fetchEventIDs(_ container: ModelContainer) throws -> [String] {
    let context = container.mainContext
    return try context.fetch(FetchDescriptor<SupervisorEvent>()).map(\.id)
  }

  private func fetchDecisionIDs(_ container: ModelContainer) throws -> [String] {
    let context = container.mainContext
    return try context.fetch(FetchDescriptor<Decision>()).map(\.id)
  }
}

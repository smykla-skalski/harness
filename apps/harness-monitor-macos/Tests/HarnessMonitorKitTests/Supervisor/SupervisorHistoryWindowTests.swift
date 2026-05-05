import SwiftData
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SupervisorHistoryWindowTests: XCTestCase {
  func test_historyWindowRetainsPerRuleEventsBeyondGlobalLimit() throws {
    let container = try ModelContainer(
      for: SupervisorEvent.self,
      Decision.self,
      PolicyConfigRow.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = container.mainContext
    let now = Date.fixed
    for index in 0..<80 {
      context.insert(
        event(
          id: "foreign-\(index)",
          ruleID: "other-rule",
          createdAt: now.addingTimeInterval(Double(index))
        )
      )
    }
    context.insert(
      event(id: "stuck-old", ruleID: "stuck-agent", createdAt: now.addingTimeInterval(-600))
    )
    try context.save()

    let history = SupervisorService.historyWindow(from: context, ruleIDs: ["stuck-agent"])

    XCTAssertTrue(history.recentEvents.contains { $0.id == "stuck-old" })
  }

  private func event(id: String, ruleID: String, createdAt: Date) -> SupervisorEvent {
    let event = SupervisorEvent(
      id: id,
      tickID: "tick-\(id)",
      kind: "actionDispatched",
      ruleID: ruleID,
      severity: .warn,
      payloadJSON: "{}"
    )
    event.createdAt = createdAt
    return event
  }
}

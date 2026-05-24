import SwiftData
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SwiftDataSchemaV7Tests: XCTestCase {
  func test_schemaContainsSupervisorEntities() throws {
    let container = try ModelContainer(
      for: Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = container.mainContext
    let decision = Decision(
      id: "d1",
      severity: .needsUser,
      ruleID: "stuck-agent",
      sessionID: "s1",
      agentID: "a1",
      taskID: nil,
      summary: "agent stalled",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
    context.insert(decision)
    try context.save()
    let loaded = try context.fetch(FetchDescriptor<Decision>())
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded.first?.id, "d1")
    XCTAssertEqual(loaded.first?.severityRaw, DecisionSeverity.needsUser.rawValue)
    XCTAssertEqual(loaded.first?.statusRaw, "open")
  }

  func test_supervisorEventRoundTripsPayload() throws {
    let container = try ModelContainer(
      for: SupervisorEvent.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = container.mainContext
    let event = SupervisorEvent(
      id: "e1",
      tickID: "t1",
      kind: "actionDispatched",
      ruleID: "stuck-agent",
      severity: .warn,
      payloadJSON: "{\"action\":\"nudge\"}"
    )
    context.insert(event)
    try context.save()
    let loaded = try context.fetch(FetchDescriptor<SupervisorEvent>())
    XCTAssertEqual(loaded.first?.payloadJSON, "{\"action\":\"nudge\"}")
    XCTAssertEqual(loaded.first?.severityRaw, DecisionSeverity.warn.rawValue)
  }

  func test_policyConfigRowPersistsParameters() throws {
    let container = try ModelContainer(
      for: PolicyConfigRow.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = container.mainContext
    let row = PolicyConfigRow(
      ruleID: "stuck-agent",
      enabled: true,
      defaultBehavior: RuleDefaultBehaviorConstants.aggressive,
      parametersJSON: "{\"threshold\":120}"
    )
    context.insert(row)
    try context.save()
    let loaded = try context.fetch(FetchDescriptor<PolicyConfigRow>())
    XCTAssertEqual(loaded.first?.ruleID, "stuck-agent")
    XCTAssertEqual(loaded.first?.defaultBehaviorRaw, "aggressive")
  }

  private enum RuleDefaultBehaviorConstants {
    static let aggressive = "aggressive"
  }
}

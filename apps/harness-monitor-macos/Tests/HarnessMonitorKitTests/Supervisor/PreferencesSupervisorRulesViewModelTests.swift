import XCTest

@testable import HarnessMonitorKit

@MainActor
final class PreferencesSupervisorRulesViewModelTests: XCTestCase {
  func test_applyRowsLoadsPersistedOverrideForSelectedRule() throws {
    let row = PolicyConfigRow(
      ruleID: "stuck-agent",
      enabled: false,
      defaultBehavior: RuleDefaultBehavior.aggressive.rawValue,
      parametersJSON: #"{"nudgeMaxRetries":"5","nudgeRetryInterval":"240","stuckThreshold":"180"}"#
    )
    let viewModel = PreferencesSupervisorRulesViewModel()

    viewModel.applyRows([row])
    viewModel.selectRule(id: "stuck-agent")

    XCTAssertEqual(viewModel.selectedRuleID, "stuck-agent")
    XCTAssertFalse(viewModel.enabled)
    XCTAssertEqual(viewModel.defaultBehavior, .aggressive)
    XCTAssertEqual(viewModel.parameterValue(for: "stuckThreshold"), "180")
    XCTAssertEqual(viewModel.parameterValue(for: "nudgeMaxRetries"), "5")
    XCTAssertEqual(viewModel.parameterValue(for: "nudgeRetryInterval"), "240")
  }

  func test_makePolicyConfigRowRoundTripsEditsThroughPolicyConfigRow() throws {
    let viewModel = PreferencesSupervisorRulesViewModel()

    viewModel.selectRule(id: "unassigned-task")
    viewModel.enabled = false
    viewModel.defaultBehavior = .cautious
    viewModel.setParameterValue("300", for: "unassignedThreshold")

    let row = try viewModel.makePolicyConfigRow()
    let reloaded = PreferencesSupervisorRulesViewModel()
    reloaded.applyRows([row])
    reloaded.selectRule(id: "unassigned-task")

    XCTAssertEqual(row.ruleID, "unassigned-task")
    XCTAssertFalse(reloaded.enabled)
    XCTAssertEqual(reloaded.defaultBehavior, .cautious)
    XCTAssertEqual(reloaded.parameterValue(for: "unassignedThreshold"), "300")
  }

  func test_resetSelectedRuleRestoresBuiltInDefaults() throws {
    let row = PolicyConfigRow(
      ruleID: "idle-session",
      enabled: false,
      defaultBehavior: RuleDefaultBehavior.aggressive.rawValue,
      parametersJSON: #"{"sessionIdleThreshold":"900"}"#
    )
    let viewModel = PreferencesSupervisorRulesViewModel()

    viewModel.applyRows([row])
    viewModel.selectRule(id: "idle-session")
    viewModel.resetSelectedRule()

    XCTAssertTrue(viewModel.enabled)
    XCTAssertEqual(viewModel.defaultBehavior, .cautious)
    XCTAssertEqual(viewModel.parameterValue(for: "sessionIdleThreshold"), "600")
  }
}

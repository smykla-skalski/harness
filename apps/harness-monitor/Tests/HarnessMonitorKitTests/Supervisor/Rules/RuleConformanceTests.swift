import Foundation
import XCTest

@testable import HarnessMonitorKit

final class RuleConformanceTests: XCTestCase {
  private let rules: [any PolicyRule] = HarnessMonitorSupervisorRuleCatalog.makeRules()

  func test_allRulesHaveNonEmptyIdentity() {
    for rule in rules {
      XCTAssertFalse(rule.id.isEmpty, "rule.id is empty for \(type(of: rule))")
      XCTAssertFalse(rule.name.isEmpty, "rule.name is empty for \(type(of: rule))")
      XCTAssertGreaterThanOrEqual(rule.version, 1, "rule.version < 1 for \(type(of: rule))")
    }
  }

  func test_allRulesHaveUniqueIDs() {
    let ids = rules.map(\.id)
    XCTAssertEqual(ids.count, Set(ids).count, "duplicate rule IDs: \(ids)")
  }

  func test_allRulesReturnDefaultBehaviorForAnyActionKey() {
    for rule in rules {
      let behavior = rule.defaultBehavior(for: "any")
      XCTAssertTrue(
        behavior == .aggressive || behavior == .cautious,
        "unexpected behavior \(behavior) for \(type(of: rule))"
      )
    }
  }

  func test_catalogCoversAllEightBuiltInRuleTypes() {
    let expectedTypes: [String] = [
      "CodexApprovalRule", "DaemonDisconnectRule", "FailedNudgeLoopRule",
      "IdleSessionRule", "ObserverIssueRule", "PolicyGapRule",
      "StuckAgentRule", "UnassignedTaskRule",
    ]
    let actualTypes = rules.map { String(describing: type(of: $0)) }
    for expected in expectedTypes {
      XCTAssertTrue(
        actualTypes.contains(expected),
        "missing rule type \(expected) in catalog"
      )
    }
  }
}

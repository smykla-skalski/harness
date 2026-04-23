import XCTest

@testable import HarnessMonitorKit

final class PolicyRegistryTests: XCTestCase {
  func test_registerAndListRulesPreservesInsertionOrder() async {
    let registry = PolicyRegistry()
    await registry.register(StubRule(id: "alpha"))
    await registry.register(StubRule(id: "bravo"))
    await registry.register(StubRule(id: "charlie"))

    let ids = await registry.allRules.map(\.id)
    XCTAssertEqual(ids, ["alpha", "bravo", "charlie"])
  }

  func test_parameterOverrideAppliedFromConfigRow() async {
    let registry = PolicyRegistry()
    await registry.register(StubRule(id: "stub"))
    await registry.applyOverrides([
      PolicyConfigOverride(
        ruleID: "stub",
        enabled: true,
        defaultBehavior: .aggressive,
        parameters: ["threshold": "120"]
      )
    ])

    let params = await registry.parameters(forRule: "stub")
    XCTAssertEqual(params.int("threshold", default: 60), 120)
  }

  func test_parametersForUnknownRuleFallsBackToDefault() async {
    let registry = PolicyRegistry()
    let params = await registry.parameters(forRule: "missing")
    XCTAssertEqual(params.int("threshold", default: 42), 42)
  }

  func test_applyOverridesReplacesPriorOverrideForSameRule() async {
    let registry = PolicyRegistry()
    await registry.register(StubRule(id: "stub"))
    await registry.applyOverrides([
      PolicyConfigOverride(
        ruleID: "stub",
        enabled: true,
        defaultBehavior: .aggressive,
        parameters: ["threshold": "60"]
      )
    ])
    await registry.applyOverrides([
      PolicyConfigOverride(
        ruleID: "stub",
        enabled: false,
        defaultBehavior: .cautious,
        parameters: ["threshold": "180"]
      )
    ])

    let params = await registry.parameters(forRule: "stub")
    XCTAssertEqual(params.int("threshold", default: 0), 180)
    let enabled = await registry.isEnabled(ruleID: "stub")
    XCTAssertFalse(enabled)
    let behavior = await registry.defaultBehavior(forRule: "stub")
    XCTAssertEqual(behavior, .cautious)
  }

  func test_isEnabledDefaultsToTrueWhenNoOverride() async {
    let registry = PolicyRegistry()
    await registry.register(StubRule(id: "stub"))
    let enabled = await registry.isEnabled(ruleID: "stub")
    XCTAssertTrue(enabled)
  }

  func test_registerObserverAddsToObserverList() async {
    let registry = PolicyRegistry()
    await registry.registerObserver(StubObserver(tag: "first"))
    await registry.registerObserver(StubObserver(tag: "second"))

    let observers = await registry.observerList
    let tags = observers.compactMap { ($0 as? StubObserver)?.tag }
    XCTAssertEqual(tags, ["first", "second"])
  }
}

// MARK: - Fixtures

private struct StubRule: PolicyRule {
  let id: String
  var name: String { id.capitalized }
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior { .cautious }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] { [] }
}

private struct StubObserver: PolicyObserver {
  let tag: String
}

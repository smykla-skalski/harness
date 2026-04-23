import Foundation

/// Registry of `PolicyRule`s and `PolicyObserver`s used by the Monitor supervisor. Phase 1
/// signature freeze: public method surface below is fixed. Phase 2 worker 3 fills bodies,
/// stable iteration order, and override merging.
public actor PolicyRegistry {
  private var rules: [any PolicyRule] = []
  private var observers: [any PolicyObserver] = []
  private var overrides: [String: PolicyConfigOverride] = [:]

  public init() {}

  /// Shared empty registry used by Phase 1 stubs and Phase 2 unit tests that want to start
  /// from a clean state.
  public static let empty = PolicyRegistry()

  public func register(_ rule: any PolicyRule) {
    rules.append(rule)
  }

  public var allRules: [any PolicyRule] {
    rules
  }

  public func applyOverrides(_ overrides: [PolicyConfigOverride]) {
    self.overrides = Dictionary(
      uniqueKeysWithValues: overrides.map { ($0.ruleID, $0) }
    )
  }

  public func clearOverrides() {
    overrides.removeAll()
  }

  public func currentOverrides() -> [PolicyConfigOverride] {
    Array(overrides.values)
  }
}

extension PolicyRegistry {
  public func registerDefaults() async {
    for rule in HarnessMonitorSupervisorRuleCatalog.makeRules() {
      register(rule)
    }
    for observer in HarnessMonitorSupervisorRuleCatalog.makeObservers() {
      registerObserver(observer)
    }
  }
}

extension PolicyRegistry {
  public func parameters(forRule ruleID: String) -> PolicyParameterValues {
    PolicyParameterValues(raw: overrides[ruleID]?.parameters ?? [:])
  }

  /// Returns `false` only when an explicit override disables the rule; defaults to `true`.
  public func isEnabled(ruleID: String) -> Bool {
    overrides[ruleID]?.enabled ?? true
  }

  /// Returns the overridden default behavior for a rule, or `.cautious` if no override exists.
  public func defaultBehavior(forRule ruleID: String) -> RuleDefaultBehavior {
    overrides[ruleID]?.defaultBehavior ?? .cautious
  }

  public var observerList: [any PolicyObserver] {
    observers
  }

  public func registerObserver(_ observer: any PolicyObserver) {
    observers.append(observer)
  }
}

public enum HarnessMonitorSupervisorRuleCatalog {
  public static func makeRules() -> [any PolicyRule] {
    [
      CodexApprovalRule(),
      DaemonDisconnectRule(),
      FailedNudgeLoopRule(),
      IdleSessionRule(),
      ObserverIssueRule(),
      PolicyGapRule(),
      StuckAgentRule(),
      UnassignedTaskRule(),
    ]
  }

  public static func makeObservers() -> [any PolicyObserver] {
    [LoggingPolicyObserver()]
  }
}

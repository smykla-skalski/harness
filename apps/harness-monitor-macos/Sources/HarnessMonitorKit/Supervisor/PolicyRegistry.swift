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
    for override in overrides {
      self.overrides[override.ruleID] = override
    }
  }

  public func parameters(forRule ruleID: String) -> PolicyParameterValues {
    PolicyParameterValues(raw: overrides[ruleID]?.parameters ?? [:])
  }

  public var observerList: [any PolicyObserver] {
    observers
  }

  public func registerObserver(_ observer: any PolicyObserver) {
    observers.append(observer)
  }
}

import Foundation

/// Runtime representation of a `PolicyConfigRow` applied to the live `PolicyRegistry`. Phase 1
/// ships the type so registry callers can pass overrides through the stubbed API.
public struct PolicyConfigOverride: Sendable, Hashable {
  public let ruleID: String
  public let enabled: Bool
  public let defaultBehavior: RuleDefaultBehavior
  public let parameters: [String: String]

  public init(
    ruleID: String,
    enabled: Bool,
    defaultBehavior: RuleDefaultBehavior,
    parameters: [String: String]
  ) {
    self.ruleID = ruleID
    self.enabled = enabled
    self.defaultBehavior = defaultBehavior
    self.parameters = parameters
  }
}

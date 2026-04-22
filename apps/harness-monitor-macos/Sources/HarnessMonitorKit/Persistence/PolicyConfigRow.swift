import Foundation
import SwiftData

/// Per-rule policy configuration row persisted in SwiftData. Parameters are serialised to JSON
/// so new parameter schemas can land without a SwiftData migration. Public field list is part
/// of the Phase 1 signature freeze.
@Model
public final class PolicyConfigRow {
  @Attribute(.unique)
  public var ruleID: String
  public var enabled: Bool
  public var defaultBehaviorRaw: String
  public var parametersJSON: String
  public var updatedAt: Date

  public init(
    ruleID: String,
    enabled: Bool,
    defaultBehavior: String,
    parametersJSON: String
  ) {
    self.ruleID = ruleID
    self.enabled = enabled
    self.defaultBehaviorRaw = defaultBehavior
    self.parametersJSON = parametersJSON
    self.updatedAt = Date()
  }
}

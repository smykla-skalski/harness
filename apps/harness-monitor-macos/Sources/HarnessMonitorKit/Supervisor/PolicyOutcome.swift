import Foundation

/// Result of handing a `PolicyAction` to the `PolicyExecutor`. Public cases are part of the
/// Phase 1 signature freeze.
public enum PolicyOutcome: Sendable, Hashable {
  case dispatched(actionKey: String)
  case skippedDuplicate(actionKey: String)
  case executed(actionKey: String)
  case failed(actionKey: String, error: String)
  case quarantined(ruleID: String, reason: String)
}

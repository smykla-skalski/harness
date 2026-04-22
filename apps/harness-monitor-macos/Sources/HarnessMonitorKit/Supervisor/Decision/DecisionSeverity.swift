import Foundation

/// Severity classification for Monitor supervisor decisions. The raw value is persisted into the
/// SwiftData `Decision` entity (`severityRaw`) so new cases must preserve the existing raw
/// strings.
public enum DecisionSeverity: String, Codable, Sendable, CaseIterable, Hashable {
  case info
  case warn
  case needsUser
  case critical
}

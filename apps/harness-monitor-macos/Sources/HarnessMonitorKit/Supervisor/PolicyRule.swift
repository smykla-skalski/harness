import Foundation

/// Declarative parameter schema attached to each `PolicyRule`. Phase 1 signature freeze.
public struct PolicyParameterSchema: Sendable, Codable, Hashable {
  public struct Field: Sendable, Codable, Hashable {
    public let key: String
    public let label: String
    public let kind: Kind
    public let `default`: String
    public let allowedValues: [String]?

    public enum Kind: String, Codable, Sendable {
      case duration
      case integer
      case boolean
      case string
    }

    public init(
      key: String,
      label: String,
      kind: Kind,
      default: String,
      allowedValues: [String]? = nil
    ) {
      self.key = key
      self.label = label
      self.kind = kind
      self.default = `default`
      self.allowedValues = allowedValues
    }
  }

  public let fields: [Field]

  public init(fields: [Field]) {
    self.fields = fields
  }
}

/// First-occurrence default behavior for a rule. Per-rule defaults are captured in the source
/// plan's resolved-decisions table.
public enum RuleDefaultBehavior: String, Codable, Sendable {
  case aggressive
  case cautious
}

/// Protocol that every built-in or user-authored supervisor rule conforms to. Part of the
/// Phase 1 signature freeze — Phase 2 worker rules conform without altering the shape.
public protocol PolicyRule: Sendable {
  var id: String { get }
  var name: String { get }
  var version: Int { get }
  var parameters: PolicyParameterSchema { get }

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction]
}

import Foundation

/// A single user-facing action attached to a Monitor supervisor `Decision`. The payload is
/// stored as a JSON string so the SwiftData row stays schema-stable when new `PolicyAction`
/// variants land.
public struct SuggestedAction: Codable, Sendable, Identifiable, Hashable {
  public let id: String
  public let title: String
  public let kind: Kind
  public let payloadJSON: String

  public enum Kind: String, Codable, Sendable {
    case nudge
    case assignTask
    case dropTask
    case snooze
    case dismiss
    case custom
  }

  public init(id: String, title: String, kind: Kind, payloadJSON: String) {
    self.id = id
    self.title = title
    self.kind = kind
    self.payloadJSON = payloadJSON
  }
}

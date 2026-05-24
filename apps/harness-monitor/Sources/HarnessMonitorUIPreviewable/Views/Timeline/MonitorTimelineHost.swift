import Foundation

public struct MonitorTimelineHost: Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    case session
    case reviewPullRequest
  }

  public let kind: Kind
  public let id: String

  public init(kind: Kind, id: String) {
    self.kind = kind
    self.id = id
  }

  public static func session(_ sessionID: String) -> Self {
    Self(kind: .session, id: sessionID)
  }

  public static func reviewPullRequest(_ pullRequestID: String) -> Self {
    Self(kind: .reviewPullRequest, id: pullRequestID)
  }

  public var storageKey: String {
    "\(kind.rawValue):\(id)"
  }
}

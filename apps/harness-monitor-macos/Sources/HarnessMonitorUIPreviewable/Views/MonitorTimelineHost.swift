import Foundation

public struct MonitorTimelineHost: Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    case session
    case agent
  }

  public let kind: Kind
  public let id: String

  public init(kind: Kind, id: String) {
    self.kind = kind
    self.id = id
  }

  public static func session(_ sessionID: String) -> MonitorTimelineHost {
    MonitorTimelineHost(kind: .session, id: sessionID)
  }

  public static func agent(_ agentID: String) -> MonitorTimelineHost {
    MonitorTimelineHost(kind: .agent, id: agentID)
  }

  public var storageKey: String {
    "\(kind.rawValue):\(id)"
  }
}

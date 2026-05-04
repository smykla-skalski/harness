import Foundation

public struct MonitorTimelineHost: Hashable, Sendable {
  // Single-variant enum reserved for future host kinds (e.g. codex run
  // panes, swarm dashboards). Today only `.session` exists; the agent
  // case was deleted when the agent pane stopped reusing the cockpit
  // pipeline. Delete this type entirely if it still has one variant the
  // next time it gets touched without a new consumer landing.
  public enum Kind: String, Hashable, Sendable {
    case session
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

  public var storageKey: String {
    "\(kind.rawValue):\(id)"
  }
}

import Foundation

public struct SessionWindowToken: Codable, Hashable, Sendable {
  public let sessionID: String

  public init(sessionID: String) {
    self.sessionID = sessionID
  }

  public var title: String {
    "Session \(sessionID)"
  }
}

public enum SessionWindowRoute: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case overview
  case agents
  case tasks
  case decisions
  case timeline
  case terminal

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .overview: "Overview"
    case .agents: "Agents"
    case .tasks: "Tasks"
    case .decisions: "Decisions"
    case .timeline: "Timeline"
    case .terminal: "Terminal/Runs"
    }
  }

  public var systemImage: String {
    switch self {
    case .overview: "rectangle.grid.2x2"
    case .agents: "person.3"
    case .tasks: "checklist"
    case .decisions: "exclamationmark.bubble"
    case .timeline: "clock"
    case .terminal: "terminal"
    }
  }
}

public enum HarnessMonitorLaunchBehavior: String, CaseIterable, Codable, Hashable,
  Identifiable, Sendable
{
  case restoreSessionWindows
  case alwaysOpenRecent

  public static let storageKey = "harness.monitor.launch-behavior"
  public static let defaultValue: Self = .restoreSessionWindows

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .restoreSessionWindows: "Restore session windows"
    case .alwaysOpenRecent: "Always show Open Recent"
    }
  }

  public var description: String {
    switch self {
    case .restoreSessionWindows:
      "Reopen session windows from system restoration when available."
    case .alwaysOpenRecent:
      "Open the recents window on launch even when session windows restore."
    }
  }

  public static func resolved(rawValue: String?) -> Self {
    Self(rawValue: rawValue ?? "") ?? defaultValue
  }

  public static func read(userDefaults: UserDefaults = .standard) -> Self {
    resolved(rawValue: userDefaults.string(forKey: storageKey))
  }
}

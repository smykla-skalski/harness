import Foundation
import HarnessMonitorKit

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
  case policyCanvas
  case decisions
  case timeline

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .overview: "Overview"
    case .agents: "Agents"
    case .tasks: "Tasks"
    case .policyCanvas: "Policy"
    case .decisions: "Decisions"
    case .timeline: "Timeline"
    }
  }

  public var systemImage: String {
    switch self {
    case .overview: "rectangle.grid.2x2"
    case .agents: "person.2"
    case .tasks: "checklist"
    case .policyCanvas: "point.3.connected.trianglepath.dotted"
    case .decisions: "exclamationmark.bubble"
    case .timeline: "clock"
    }
  }

  public var appSearchDomain: AppSearchDomain? {
    switch self {
    case .agents: .agents
    case .decisions: .decisions
    case .tasks: .tasks
    case .timeline: .timeline
    case .overview, .policyCanvas: nil
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
  public static let closingBehaviorDescription =
    "Command-W or the red close button removes a session window from relaunch. "
    + "Windows left open at quit restore open; minimized session windows restore visible"

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
      "Reopen session windows from system restoration when available"
    case .alwaysOpenRecent:
      "Open the recents window on launch even when session windows restore"
    }
  }

  public static func resolved(rawValue: String?) -> Self {
    Self(rawValue: rawValue ?? "") ?? defaultValue
  }

  public static func read(userDefaults: UserDefaults = .standard) -> Self {
    resolved(rawValue: userDefaults.string(forKey: storageKey))
  }
}

public enum OpenRecentCloseAfterPickDefaults {
  public static let storageKey = "harness.monitor.open-recent.close-after-pick"
  public static let defaultValue = true

  public static func read(userDefaults: UserDefaults = .standard) -> Bool {
    if userDefaults.object(forKey: storageKey) == nil {
      return defaultValue
    }
    return userDefaults.bool(forKey: storageKey)
  }
}

public enum SessionPendingDecisionBannerSettings {
  public static let enabledKey = "harness.monitor.decisions.pending-banner-enabled"
  public static let focusModeEnabledKey = "harness.monitor.decisions.pending-banner.focus-mode"
  public static let enabledDefaultValue = true
  public static let focusModeEnabledDefaultValue = true

  public static func registrationDefaults() -> [String: Any] {
    [
      enabledKey: enabledDefaultValue,
      focusModeEnabledKey: focusModeEnabledDefaultValue,
    ]
  }

  public static func readEnabled(userDefaults: UserDefaults = .standard) -> Bool {
    if userDefaults.object(forKey: enabledKey) == nil {
      return enabledDefaultValue
    }
    return userDefaults.bool(forKey: enabledKey)
  }

  public static func readFocusModeEnabled(userDefaults: UserDefaults = .standard) -> Bool {
    if userDefaults.object(forKey: focusModeEnabledKey) == nil {
      return focusModeEnabledDefaultValue
    }
    return userDefaults.bool(forKey: focusModeEnabledKey)
  }

  public static func showsBanner(
    isFocusMode: Bool,
    userDefaults: UserDefaults = .standard
  ) -> Bool {
    readEnabled(userDefaults: userDefaults)
      && (!isFocusMode || readFocusModeEnabled(userDefaults: userDefaults))
  }
}

public enum SessionWindowTabbingPreference: String, CaseIterable, Codable, Hashable,
  Identifiable, Sendable
{
  case system
  case always
  case never

  public static let storageKey = "harness.monitor.session-window.tabbing"
  public static let defaultValue: Self = .system

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .system: "System"
    case .always: "Always"
    case .never: "Never"
    }
  }

  public var description: String {
    switch self {
    case .system:
      "Follow the macOS setting for opening windows as tabs"
    case .always:
      "Prefer native tabs for session windows"
    case .never:
      "Open session windows as separate windows"
    }
  }

  public static func resolved(rawValue: String?) -> Self {
    Self(rawValue: rawValue ?? "") ?? defaultValue
  }
}

public enum SessionWindowKeyboardShortcutOverlaySettings {
  public static let storageKey = "harness.monitor.session-window.shortcut-overlays-enabled"
  public static let defaultValue = true

  public static func read(userDefaults: UserDefaults = .standard) -> Bool {
    if userDefaults.object(forKey: storageKey) == nil {
      return defaultValue
    }
    return userDefaults.bool(forKey: storageKey)
  }
}

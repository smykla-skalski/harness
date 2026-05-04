import AppKit

public enum MonitorTimelineLiveRegionPriority {
  case silent
  case polite
  case assertive
}

public enum MonitorTimelineLiveRegion {
  public static func priority(for kind: String) -> MonitorTimelineLiveRegionPriority {
    switch kind {
    case "tool_result",
      "tool_result_error",
      "agent_context_injected",
      "plan_update":
      .polite
    case "agent_permission_asked",
      "agent_watchdog_state",
      "agent_hook_fired",
      "agent_session_marker",
      "agent_error":
      .assertive
    default:
      .silent
    }
  }

  @MainActor
  public static func announce(
    _ summary: String,
    priority: MonitorTimelineLiveRegionPriority
  ) {
    guard priority != .silent else { return }
    let level: NSAccessibilityPriorityLevel = priority == .assertive ? .high : .medium
    let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
      .announcement: summary,
      .priority: level.rawValue,
    ]
    let target = NSApp.mainWindow ?? NSApp.keyWindow
    if let target {
      NSAccessibility.post(
        element: target,
        notification: .announcementRequested,
        userInfo: userInfo
      )
    }
  }
}

@MainActor
public final class MonitorTimelineLiveRegionThrottle: ObservableObject {
  private var lastPolite: Date?
  private static let politeMinimumGap: TimeInterval = 1.0
  private static let coalesceWindow: TimeInterval = 0.5
  private var pendingPoliteAt: Date?

  public init() {}

  public func announceIfAllowed(
    _ summary: String,
    priority: MonitorTimelineLiveRegionPriority,
    now: Date = .now
  ) {
    switch priority {
    case .silent:
      return
    case .polite:
      if let last = lastPolite, now.timeIntervalSince(last) < Self.politeMinimumGap {
        return
      }
      if let pending = pendingPoliteAt, now.timeIntervalSince(pending) < Self.coalesceWindow {
        return
      }
      pendingPoliteAt = now
      lastPolite = now
      MonitorTimelineLiveRegion.announce(summary, priority: .polite)
    case .assertive:
      MonitorTimelineLiveRegion.announce(summary, priority: .assertive)
    }
  }
}

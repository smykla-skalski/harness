import AppKit
import OSLog

public enum MonitorTimelineLiveRegionPriority {
  case silent
  case polite
  case assertive
}

public enum MonitorTimelineLiveRegion {
  public static func priority(for kind: String) -> MonitorTimelineLiveRegionPriority {
    switch kind {
    case "tool_result", "tool_result_error":
      .polite
    case "agent_watchdog_state",
      "agent_session_marker",
      "agent_error":
      .assertive
    default:
      .silent
    }
  }

  private static let logger = Logger(
    subsystem: "com.harness.monitor",
    category: "live-region"
  )

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
    let target = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first
    guard let target else {
      logger.warning(
        "dropped announcement; no window available: \(summary, privacy: .public)"
      )
      return
    }
    NSAccessibility.post(
      element: target,
      notification: .announcementRequested,
      userInfo: userInfo
    )
  }
}

// Polite announcements are throttled to one per second so VoiceOver does
// not get flooded during ACP transcript bursts; assertive bypasses the
// throttle so permission prompts and watchdog transitions reach the user
// immediately. Elapsed time uses the monotonic continuous clock so a
// suspend/resume or NTP step cannot freeze the throttle window.
@MainActor
public final class MonitorTimelineLiveRegionThrottle: ObservableObject {
  private(set) var lastPoliteInstant: ContinuousClock.Instant?
  private static let politeMinimumGap: Duration = .seconds(1)

  public init() {}

  public func announceIfAllowed(
    _ summary: String,
    priority: MonitorTimelineLiveRegionPriority,
    now: ContinuousClock.Instant = .now
  ) {
    switch priority {
    case .silent:
      return
    case .polite:
      // Drops do not advance the cooldown; only successful announcements do.
      // Hoisting `lastPoliteInstant = now` above the early-return would silence
      // every follow-up announcement for the full politeMinimumGap window
      // after each drop, instead of after each successful announcement.
      if let last = lastPoliteInstant, last.duration(to: now) < Self.politeMinimumGap {
        return
      }
      lastPoliteInstant = now
      MonitorTimelineLiveRegion.announce(summary, priority: .polite)
    case .assertive:
      MonitorTimelineLiveRegion.announce(summary, priority: .assertive)
    }
  }
}

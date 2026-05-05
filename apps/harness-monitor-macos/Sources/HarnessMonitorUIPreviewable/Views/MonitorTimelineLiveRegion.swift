import AppKit
import OSLog

public enum MonitorTimelineLiveRegionPriority {
  case silent
  case polite
  case assertive
}

public enum MonitorTimelineLiveRegion {
  public static func priority(
    for kind: String,
    summary: String = ""
  ) -> MonitorTimelineLiveRegionPriority {
    switch kind {
    case "tool_result", "tool_result_error", "agent_context_injected":
      return .polite
    case "agent_watchdog_state":
      let lower = summary.lowercased()
      if lower.contains("fired") || lower.contains("expired") || lower.contains("timed") {
        return .assertive
      }
      return .polite
    case "agent_session_marker", "agent_error", "agent_permission_asked":
      return .assertive
    case "signal_sent", "signal_received":
      return .polite
    case "signal_acknowledged":
      let lower = summary.lowercased()
      if lower.contains("rejected") || lower.contains("expired") || lower.contains("deferred") {
        return .assertive
      }
      return .polite
    default:
      return .silent
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

// Polite announcements are throttled to one every 10 seconds (~6/min) so
// VoiceOver does not get flooded during ACP transcript bursts; assertive
// bypasses the throttle so permission prompts and watchdog-fired
// transitions reach the user immediately. Drops between gaps are
// counted, and the next successful polite announcement prepends a
// rollup phrase ("Plus N more updates. ") so the user can stay aware of
// activity without being interrupted on every event. Elapsed time uses
// the monotonic continuous clock so a suspend/resume or NTP step cannot
// freeze the throttle window.
@MainActor
public final class MonitorTimelineLiveRegionThrottle: ObservableObject {
  private(set) var lastPoliteInstant: ContinuousClock.Instant?
  private(set) var droppedPoliteSinceLast: Int = 0
  private static let politeMinimumGap: Duration = .seconds(10)

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
        droppedPoliteSinceLast += 1
        return
      }
      lastPoliteInstant = now
      let composed = Self.composeRolledUpSummary(
        summary,
        droppedSinceLast: droppedPoliteSinceLast
      )
      droppedPoliteSinceLast = 0
      MonitorTimelineLiveRegion.announce(composed, priority: .polite)
    case .assertive:
      MonitorTimelineLiveRegion.announce(summary, priority: .assertive)
    }
  }

  static func composeRolledUpSummary(
    _ summary: String,
    droppedSinceLast: Int
  ) -> String {
    guard droppedSinceLast > 0 else {
      return summary
    }
    let suffix = droppedSinceLast == 1 ? "" : "s"
    return "Plus \(droppedSinceLast) more update\(suffix). \(summary)"
  }
}

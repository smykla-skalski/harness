import Foundation

public enum HarnessMonitorTimelineTrace {
  public static let environmentKey = "HARNESS_MONITOR_TIMELINE_TRACE"
  public static let defaultsKey = "HarnessMonitorTimelineTraceEnabled"

  private static let environmentEnabled =
    ProcessInfo.processInfo.environment[environmentKey] == "1"

  public static var isEnabled: Bool {
    isEnabled(environmentEnabled: environmentEnabled, defaults: .standard)
  }

  public static func info(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    writeInfo(message())
  }

  static func isEnabled(environmentEnabled: Bool, defaults: UserDefaults) -> Bool {
    environmentEnabled || defaults.bool(forKey: defaultsKey)
  }

  static func log(_ message: () -> String, enabled: Bool) {
    guard enabled else { return }
    writeInfo(message())
  }

  private static func writeInfo(_ message: String) {
    HarnessMonitorLogger.timeline.info("\(message, privacy: .public)")
  }

  public static func requestSummary(_ request: TimelineWindowRequest) -> String {
    if let before = request.before {
      return "before:\(before.entryId):limit=\(request.limit ?? -1)"
    }
    if let after = request.after {
      return "after:\(after.entryId):limit=\(request.limit ?? -1)"
    }
    return "latest:limit=\(request.limit ?? -1)"
  }

  public static func windowSummary(_ window: TimelineWindowResponse?) -> String {
    guard let window else {
      return "window=nil"
    }
    return
      """
      rev=\(window.revision) total=\(window.totalCount) \
      start=\(window.windowStart) end=\(window.windowEnd) \
      hasOlder=\(window.hasOlder) hasNewer=\(window.hasNewer) \
      entries=\(window.entries?.count ?? -1) unchanged=\(window.unchanged)
      """
  }
}

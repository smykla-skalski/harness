import OSLog
import SwiftUI

public enum ViewBodySignposter {
  private static let bridge = HarnessMonitorSignpostBridge(
    subsystem: "io.harnessmonitor",
    category: "view"
  )
  private static let profileEnvKey = "HARNESS_MONITOR_PROFILE_VIEW_BODIES"
  private static let perfScenarioEnvKey = "HARNESS_MONITOR_PERF_SCENARIO"
  private static let updateLoggingEnvKey = "HARNESS_MONITOR_LOG_VIEW_UPDATES"

  private static var automaticProfilingEnabled: Bool {
    let environment = ProcessInfo.processInfo.environment
    if environment[profileEnvKey] == "1" {
      return true
    }
    guard
      let perfScenario = environment[perfScenarioEnvKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !perfScenario.isEmpty
    else {
      return false
    }
    return true
  }

  static func shouldLogChanges(
    for viewName: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    guard
      let rawValue = environment[updateLoggingEnvKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.isEmpty
    else {
      return false
    }
    if rawValue == "1" || rawValue.caseInsensitiveCompare("all") == .orderedSame {
      return true
    }

    let selectedViews =
      rawValue
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    return selectedViews.contains(viewName)
  }

  @MainActor
  private static func logChangesIfEnabled<V: View>(
    _ viewType: V.Type,
    viewName: String
  ) {
    guard shouldLogChanges(for: viewName) else {
      return
    }
    if #available(macOS 14.2, *) {
      viewType._logChanges()
    } else {
      viewType._printChanges()
    }
  }

  public static func measure<T>(
    _ viewName: String,
    attributes: [String: String] = [:],
    body: () -> T
  ) -> T {
    let (state, span) = bridge.beginInterval(name: "view.body")
    span.setAttribute(key: "harness.view.name", value: viewName)
    for (key, value) in attributes {
      span.setAttribute(key: key, value: value)
    }
    defer { bridge.endInterval(name: "view.body", state: state) }
    return body()
  }

  public static func profile<T>(
    _ viewName: String,
    attributes: [String: String] = [:],
    body: () -> T
  ) -> T {
    guard automaticProfilingEnabled else {
      return body()
    }
    return measure(viewName, attributes: attributes, body: body)
  }

  @MainActor
  public static func trace<V: View, T>(
    _ viewType: V.Type,
    _ viewName: String,
    attributes: [String: String] = [:],
    body: () -> T
  ) -> T {
    logChangesIfEnabled(viewType, viewName: viewName)
    return profile(viewName, attributes: attributes, body: body)
  }
}

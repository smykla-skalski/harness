import OSLog
import SwiftUI

public enum ViewBodySignposter {
  private enum UpdateLoggingSelection: Sendable {
    case disabled
    case all
    case views(Set<String>)

    func includes(_ viewName: String) -> Bool {
      switch self {
      case .disabled:
        false
      case .all:
        true
      case .views(let selectedViews):
        selectedViews.contains(viewName)
      }
    }
  }

  private struct LaunchConfiguration: Sendable {
    let automaticProfilingEnabled: Bool
    let updateLoggingSelection: UpdateLoggingSelection
    let allowsDynamicTestOverrides: Bool

    init(environment: [String: String]) {
      automaticProfilingEnabled = ViewBodySignposter.isAutomaticProfilingEnabled(
        environment: environment
      )
      updateLoggingSelection = ViewBodySignposter.updateLoggingSelection(
        environment: environment
      )
      allowsDynamicTestOverrides = environment["XCTestConfigurationFilePath"] != nil
    }
  }

  #if HARNESS_FEATURE_OTEL
    private static let bridge = HarnessMonitorSignpostBridge(
      subsystem: "io.harnessmonitor",
      category: "view"
    )
  #else
    private static let signposter = OSSignposter(
      subsystem: "io.harnessmonitor",
      category: "view"
    )
  #endif
  private static let profileEnvKey = "HARNESS_MONITOR_PROFILE_VIEW_BODIES"
  private static let perfScenarioEnvKey = "HARNESS_MONITOR_PERF_SCENARIO"
  private static let updateLoggingEnvKey = "HARNESS_MONITOR_LOG_VIEW_UPDATES"
  private static let launchConfiguration = LaunchConfiguration(
    environment: ProcessInfo.processInfo.environment
  )

  private static var automaticProfilingEnabled: Bool {
    #if DEBUG
      if launchConfiguration.allowsDynamicTestOverrides {
        return isAutomaticProfilingEnabled(
          environment: ProcessInfo.processInfo.environment
        )
      }
    #endif
    return launchConfiguration.automaticProfilingEnabled
  }

  static func isAutomaticProfilingEnabled(environment: [String: String]) -> Bool {
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
    environment: [String: String]
  ) -> Bool {
    updateLoggingSelection(environment: environment).includes(viewName)
  }

  private static func updateLoggingSelection(
    environment: [String: String]
  ) -> UpdateLoggingSelection {
    guard
      let rawValue = environment[updateLoggingEnvKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.isEmpty
    else {
      return .disabled
    }
    if rawValue == "1" || rawValue.caseInsensitiveCompare("all") == .orderedSame {
      return .all
    }

    let selectedViews =
      rawValue
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    return .views(Set(selectedViews))
  }

  private static func shouldLogLaunchChanges(for viewName: String) -> Bool {
    #if DEBUG
      if launchConfiguration.allowsDynamicTestOverrides {
        return shouldLogChanges(
          for: viewName,
          environment: ProcessInfo.processInfo.environment
        )
      }
    #endif
    return launchConfiguration.updateLoggingSelection.includes(viewName)
  }

  @MainActor
  private static func logChangesIfEnabled<V: View>(
    _ viewType: V.Type,
    viewName: String
  ) {
    guard shouldLogLaunchChanges(for: viewName) else {
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
    #if HARNESS_FEATURE_OTEL
      let (state, span) = bridge.beginInterval(name: "view.body")
      span.setAttribute(key: "harness.view.name", value: viewName)
      for (key, value) in attributes {
        span.setAttribute(key: key, value: value)
      }
      defer { bridge.endInterval(name: "view.body", state: state) }
      return body()
    #else
      _ = attributes
      _ = viewName
      let state = signposter.beginInterval("view.body", id: .exclusive)
      defer { signposter.endInterval("view.body", state) }
      return body()
    #endif
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
    HarnessMonitorPerfTrace.countBodyEval(viewName)
    return profile(viewName, attributes: attributes, body: body)
  }
}

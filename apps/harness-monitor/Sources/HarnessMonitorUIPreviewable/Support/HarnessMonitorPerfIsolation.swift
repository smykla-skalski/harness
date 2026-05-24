import Foundation

public enum HarnessMonitorPerfIsolation {
  public static let disableSearchHostKey = "HARNESS_MONITOR_PERF_DISABLE_SEARCH_HOST"
  public static let disableSearchSuggestionsKey =
    "HARNESS_MONITOR_PERF_DISABLE_SEARCH_SUGGESTIONS"
  public static let enableSceneWritesKey = "HARNESS_MONITOR_PERF_ENABLE_SCENE_WRITES"
  public static let staticDetailKey = "HARNESS_MONITOR_PERF_STATIC_DETAIL"

  public static var disablesSearchHost: Bool {
    isActiveFlag(disableSearchHostKey)
  }

  public static var disablesSearchSuggestions: Bool {
    isActiveFlag(disableSearchSuggestionsKey)
  }

  public static var usesStaticDetail: Bool {
    isActiveFlag(staticDetailKey)
  }

  public static var allowsSceneRestorationWrites: Bool {
    !HarnessMonitorUITestEnvironment.isPerfScenarioActive || isActiveFlag(enableSceneWritesKey)
  }

  private static func isActiveFlag(_ key: String) -> Bool {
    guard HarnessMonitorUITestEnvironment.isPerfScenarioActive else { return false }
    let rawValue = ProcessInfo.processInfo.environment[key]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return rawValue == "1" || rawValue == "true" || rawValue == "yes"
  }
}

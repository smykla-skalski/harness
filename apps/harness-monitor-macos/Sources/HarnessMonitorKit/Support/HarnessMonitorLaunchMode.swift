import Foundation

public enum HarnessMonitorLaunchMode: String, Equatable, Sendable {
  public static let environmentKey = "HARNESS_MONITOR_LAUNCH_MODE"
  public static let xcodePreviewEnvironmentKey = "XCODE_RUNNING_FOR_PREVIEWS"
  public static let xcodePlaygroundsEnvironmentKey = "XCODE_RUNNING_FOR_PLAYGROUNDS"

  case live
  case preview
  case empty

  public init(environment: [String: String]) {
    let explicitValue = environment[Self.environmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    if let explicitValue, let explicitMode = Self(rawValue: explicitValue) {
      self = explicitMode
      return
    }

    let isRunningForPreviewExecutor =
      environment[Self.xcodePreviewEnvironmentKey] == "1"
      || environment[Self.xcodePlaygroundsEnvironmentKey] == "1"
    self = isRunningForPreviewExecutor ? .preview : .live
  }

  public init(environment: HarnessMonitorEnvironment) {
    self.init(environment: environment.values)
  }
}

public enum HarnessMonitorAppVisibilityPolicy {
  public static func shouldSuspendLiveConnection(
    appIsHidden: Bool,
    hasVisibleNonMiniaturizedWindows: Bool
  ) -> Bool {
    appIsHidden || hasVisibleNonMiniaturizedWindows == false
  }
}

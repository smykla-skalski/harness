import Foundation

public enum HarnessMonitorLaunchMode: String, Equatable, Sendable {
  public static let environmentKey = "HARNESS_MONITOR_LAUNCH_MODE"

  case live
  case preview
  case empty

  public init(environment: [String: String]) {
    let rawValue = environment[Self.environmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    self = Self(rawValue: rawValue ?? "") ?? .live
  }

  public init(environment: HarnessMonitorEnvironment) {
    self.init(environment: environment.values)
  }
}

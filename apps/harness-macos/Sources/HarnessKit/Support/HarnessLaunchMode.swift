import Foundation

public enum HarnessLaunchMode: String, Equatable, Sendable {
  public static let environmentKey = "HARNESS_LAUNCH_MODE"

  case live
  case preview
  case empty

  public init(environment: [String: String]) {
    let rawValue = environment[Self.environmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    self = Self(rawValue: rawValue ?? "") ?? .live
  }

  public init(environment: HarnessEnvironment) {
    self.init(environment: environment.values)
  }
}

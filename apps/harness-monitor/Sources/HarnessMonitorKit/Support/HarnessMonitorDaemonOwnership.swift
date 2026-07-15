import Foundation

/// Who owns the daemon lifecycle at runtime.
///
/// - `managed`: Harness Monitor registers and starts the daemon via
///   `SMAppService`.
/// - `external`: the daemon is launched by the developer in a terminal
///   via `harness-daemon dev`; the app only reads the manifest and
///   connects. Supported in development and production when the app can
///   resolve the daemon manifest through the shared runtime root.
public enum DaemonOwnership: String, Equatable, Hashable, Sendable, CaseIterable {
  public static let environmentKey = "HARNESS_MONITOR_EXTERNAL_DAEMON"
  public static let preferenceKey = "HarnessMonitor.DaemonOwnership"

  case managed
  case external

  public init(environment: [String: String]) {
    self = Self.resolved(flag: environment[Self.environmentKey]) ?? .managed
  }

  public init(environment: HarnessMonitorEnvironment) {
    self.init(environment: environment.values)
  }

  public static func persistedPreference(defaults: UserDefaults = .standard) -> Self? {
    resolved(flag: defaults.string(forKey: Self.preferenceKey))
  }

  public var settingsLabel: String {
    switch self {
    case .managed:
      "Managed (SMAppService)"
    case .external:
      "External (CLI)"
    }
  }

  private static func resolved(flag rawValue: String?) -> Self? {
    guard
      let normalized = rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
      !normalized.isEmpty
    else {
      return nil
    }

    switch normalized {
    case "1", "true", "yes", "on", Self.external.rawValue:
      return .external
    case "0", "false", "no", "off", Self.managed.rawValue:
      return .managed
    default:
      return nil
    }
  }
}

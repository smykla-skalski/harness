import Foundation

/// Who owns the daemon lifecycle at runtime.
///
/// - `managed`: Harness Monitor registers and starts the daemon via
///   `SMAppService`. This is the only supported release-build path.
/// - `external`: the daemon is launched by the developer in a terminal
///   via `harness daemon dev`; the app only reads the manifest and
///   connects. Gated behind `#if DEBUG` so release builds always resolve
///   to `.managed`.
public enum DaemonOwnership: String, Equatable, Sendable, CaseIterable {
  public static let environmentKey = "HARNESS_MONITOR_EXTERNAL_DAEMON"

  case managed
  case external

  public init(environment: [String: String]) {
    #if DEBUG
      let raw = environment[Self.environmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      switch raw {
      case "1", "true", "yes", "on":
        self = .external
      default:
        self = .managed
      }
    #else
      _ = environment
      self = .managed
    #endif
  }

  public init(environment: HarnessMonitorEnvironment) {
    self.init(environment: environment.values)
  }
}

import Foundation

public struct MonitorEnvironment: Equatable, Sendable {
  public let values: [String: String]
  public let homeDirectory: URL

  public init(
    values: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.values = values
    self.homeDirectory = homeDirectory
  }

  public static let current = Self()
}

public enum MonitorPaths {
  public static func dataRoot(using environment: MonitorEnvironment = .current) -> URL {
    let value = environment.values["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let value, !value.isEmpty {
      return URL(fileURLWithPath: value, isDirectory: true)
    }

    return environment.homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
  }

  public static func harnessRoot(using environment: MonitorEnvironment = .current) -> URL {
    Self.dataRoot(using: environment).appendingPathComponent("harness", isDirectory: true)
  }

  public static func daemonRoot(using environment: MonitorEnvironment = .current) -> URL {
    Self.harnessRoot(using: environment).appendingPathComponent("daemon", isDirectory: true)
  }

  public static func manifestURL(using environment: MonitorEnvironment = .current) -> URL {
    Self.daemonRoot(using: environment).appendingPathComponent("manifest.json")
  }

  public static func authTokenURL(using environment: MonitorEnvironment = .current) -> URL {
    Self.daemonRoot(using: environment).appendingPathComponent("auth-token")
  }

  public static func launchAgentURL(using environment: MonitorEnvironment = .current) -> URL {
    environment.homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("LaunchAgents", isDirectory: true)
      .appendingPathComponent("io.harness.monitor.daemon.plist")
  }
}

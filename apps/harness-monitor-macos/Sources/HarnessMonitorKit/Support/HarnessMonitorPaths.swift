import Foundation

public struct HarnessMonitorEnvironment: Equatable, Sendable {
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

public enum HarnessMonitorPaths {
  public static func dataRoot(using environment: HarnessMonitorEnvironment = .current) -> URL {
    let value = environment.values["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let value, !value.isEmpty {
      return URL(fileURLWithPath: value, isDirectory: true)
    }

    return environment.homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
  }

  public static func harnessRoot(using environment: HarnessMonitorEnvironment = .current) -> URL {
    Self.dataRoot(using: environment).appendingPathComponent("harness", isDirectory: true)
  }

  public static func daemonRoot(using environment: HarnessMonitorEnvironment = .current) -> URL {
    Self.harnessRoot(using: environment).appendingPathComponent("daemon", isDirectory: true)
  }

  public static func manifestURL(using environment: HarnessMonitorEnvironment = .current) -> URL {
    Self.daemonRoot(using: environment).appendingPathComponent("manifest.json")
  }

  public static func authTokenURL(using environment: HarnessMonitorEnvironment = .current) -> URL {
    Self.daemonRoot(using: environment).appendingPathComponent("auth-token")
  }

  public static func thumbnailCacheRoot(using environment: HarnessMonitorEnvironment = .current) -> URL {
    Self.harnessRoot(using: environment)
      .appendingPathComponent("cache", isDirectory: true)
      .appendingPathComponent("thumbnails", isDirectory: true)
  }

  public static func launchAgentURL(using environment: HarnessMonitorEnvironment = .current) -> URL {
    environment.homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("LaunchAgents", isDirectory: true)
      .appendingPathComponent("io.harness.daemon.plist")
  }
}

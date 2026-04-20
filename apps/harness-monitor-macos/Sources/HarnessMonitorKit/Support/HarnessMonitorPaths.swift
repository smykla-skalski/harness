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

public enum HarnessMonitorAppGroup {
  public static let identifier = "Q498EB36N4.io.harnessmonitor"
  public static let environmentKey = "HARNESS_APP_GROUP_ID"
  public static let daemonDataHomeEnvironmentKey = "HARNESS_DAEMON_DATA_HOME"
}

public enum HarnessMonitorPaths {
  public static func sharedObservabilityConfigURL(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    sharedObservabilityRoot(using: environment)
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("observability", isDirectory: true)
      .appendingPathComponent("config.json")
  }

  public static func dataRoot(using environment: HarnessMonitorEnvironment = .current) -> URL {
    if let base = resolveBaseRoot(using: environment, preferExternalDaemon: true) {
      return base
    }
    return appGroupContainerURL(identifier: HarnessMonitorAppGroup.identifier, using: environment)
  }

  /// Resolves the base data-root URL using a consistent priority chain.
  ///
  /// Resolution order:
  /// 1. Explicit configured root (`HARNESS_DAEMON_DATA_HOME` / `XDG_DATA_HOME`).
  /// 2. App group container override via `HARNESS_APP_GROUP_ID` env var.
  /// 3. System `containerURL(forSecurityApplicationGroupIdentifier:)`.
  /// 4. External-daemon bypass (`HARNESS_MONITOR_EXTERNAL_DAEMON=1`, debug builds only):
  ///    returns `~/Library/Application Support` directly so dev mode skips the
  ///    group-container lookup and stays symmetric with the pre-Task-11 behaviour.
  ///    Only evaluated when `preferExternalDaemon` is true.
  ///
  /// Returns `nil` when none of the above resolves — callers decide how to handle that.
  private static func resolveBaseRoot(
    using environment: HarnessMonitorEnvironment,
    preferExternalDaemon: Bool
  ) -> URL? {
    if let configuredRoot = configuredDataHomeRoot(using: environment) {
      return configuredRoot
    }

    if let value = environment.values[HarnessMonitorAppGroup.environmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    {
      return appGroupContainerURL(identifier: value, using: environment)
    }

    if let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: HarnessMonitorAppGroup.identifier
    ) {
      return containerURL
    }

    if preferExternalDaemon, DaemonOwnership(environment: environment) == .external {
      return environment.homeDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
    }

    return nil
  }

  private static func appGroupContainerURL(
    identifier: String,
    using environment: HarnessMonitorEnvironment
  ) -> URL {
    environment.homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Group Containers", isDirectory: true)
      .appendingPathComponent(identifier, isDirectory: true)
  }

  private static func sharedObservabilityRoot(
    using environment: HarnessMonitorEnvironment
  ) -> URL {
    if let configuredRoot = configuredDataHomeRoot(using: environment) {
      return configuredRoot
    }

    return environment.homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
  }

  private static func configuredDataHomeRoot(
    using environment: HarnessMonitorEnvironment
  ) -> URL? {
    let daemonDataHomeValue = environment.values[
      HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let daemonDataHomeValue, !daemonDataHomeValue.isEmpty {
      return URL(fileURLWithPath: daemonDataHomeValue, isDirectory: true)
    }

    let xdgDataHomeValue = environment.values["XDG_DATA_HOME"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let xdgDataHomeValue, !xdgDataHomeValue.isEmpty {
      return URL(fileURLWithPath: xdgDataHomeValue, isDirectory: true)
    }

    return nil
  }

  public static func harnessRoot(using environment: HarnessMonitorEnvironment = .current) -> URL {
    if let base = resolveBaseRoot(using: environment, preferExternalDaemon: true) {
      return base.appendingPathComponent("harness", isDirectory: true)
    }

    // resolveBaseRoot returned nil: the group container was unavailable.
    // In a managed (sandboxed release) build this is a non-recoverable misconfiguration —
    // the app lacks the required entitlement and any I/O to the legacy path will be denied.
    if DaemonOwnership(environment: environment) == .managed {
      HarnessMonitorLogger.store.error(
        "Group container unavailable in managed build — check app group entitlement"
      )
      fatalError("group container unavailable in managed build — check app group entitlement")
    }

    // Debug or external-daemon fallback: the app is unsandboxed, so the legacy path is accessible.
    HarnessMonitorLogger.store.warning(
      "App group container unavailable; falling back to ~/Library/Application Support/harness"
    )
    return environment.homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("harness", isDirectory: true)
  }

  public static func daemonRoot(using environment: HarnessMonitorEnvironment = .current) -> URL {
    Self.harnessRoot(using: environment).appendingPathComponent("daemon", isDirectory: true)
  }

  public static func cacheStoreURL(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    Self.harnessRoot(using: environment)
      .appendingPathComponent("harness-cache.store")
  }

  public static func manifestURL(using environment: HarnessMonitorEnvironment = .current) -> URL {
    Self.daemonRoot(using: environment).appendingPathComponent("manifest.json")
  }

  public static func authTokenURL(using environment: HarnessMonitorEnvironment = .current) -> URL {
    Self.daemonRoot(using: environment).appendingPathComponent("auth-token")
  }

  public static func managedLaunchAgentBundleStampURL(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    Self.daemonRoot(using: environment)
      .appendingPathComponent("managed-launch-agent-bundle-stamp.json")
  }

  public static func thumbnailCacheRoot(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    Self.harnessRoot(using: environment)
      .appendingPathComponent("cache", isDirectory: true)
      .appendingPathComponent("thumbnails", isDirectory: true)
  }

  public static var launchAgentPlistName: String {
    "io.harnessmonitor.daemon.plist"
  }

  public static var launchAgentBundleRelativePath: String {
    "Contents/Library/LaunchAgents/\(launchAgentPlistName)"
  }
}

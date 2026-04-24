import Foundation
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

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

  public static var current: Self {
    Self(
      values: currentProcessValues(),
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )
  }

  public var isXCTestProcess: Bool {
    values["XCTestConfigurationFilePath"] != nil
      || values["HARNESS_MONITOR_UI_TESTS"] == "1"
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      || ProcessInfo.processInfo.environment["HARNESS_MONITOR_UI_TESTS"] == "1"
      || ProcessInfo.processInfo.processName == "xctest"
  }

  private static func currentProcessValues() -> [String: String] {
    var values = ProcessInfo.processInfo.environment
    for key in liveEnvironmentOverrideKeys {
      if let value = currentCEnvironmentValue(for: key) {
        values[key] = value
      } else {
        values.removeValue(forKey: key)
      }
    }
    return values
  }

  private static func currentCEnvironmentValue(for key: String) -> String? {
    key.withCString { namePointer in
      guard let valuePointer = getenv(namePointer) else { return nil }
      return String(cString: valuePointer)
    }
  }

  private static let liveEnvironmentOverrideKeys = [
    HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey,
    HarnessMonitorAppGroup.environmentKey,
    "HARNESS_MONITOR_EXTERNAL_DAEMON",
    "XDG_DATA_HOME",
  ]
}

public enum HarnessMonitorAppGroup {
  public static let identifier = "Q498EB36N4.io.harnessmonitor"
  public static let environmentKey = "HARNESS_APP_GROUP_ID"
  public static let daemonDataHomeEnvironmentKey = "HARNESS_DAEMON_DATA_HOME"
}

public enum HarnessMonitorPaths {
  public static func generatedCacheRoot(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    Self.harnessRoot(using: environment)
      .appendingPathComponent("cache.noindex", isDirectory: true)
  }

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
  /// 2. Native group-container resolution for the configured or default app group id.
  /// 3. Home-relative app-group fallback via `HARNESS_APP_GROUP_ID`.
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

    if let appGroupIdentifier = normalizedAppGroupIdentifier(using: environment) {
      if let containerURL = nativeAppGroupContainerURL(
        identifier: appGroupIdentifier,
        using: environment
      ) {
        return containerURL
      }
      return appGroupContainerURL(identifier: appGroupIdentifier, using: environment)
    }

    if let containerURL = nativeAppGroupContainerURL(
      identifier: HarnessMonitorAppGroup.identifier,
      using: environment
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

  private static func normalizedAppGroupIdentifier(
    using environment: HarnessMonitorEnvironment
  ) -> String? {
    guard
      let value = environment.values[HarnessMonitorAppGroup.environmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }

  private static func nativeAppGroupContainerURL(
    identifier: String,
    using environment: HarnessMonitorEnvironment
  ) -> URL? {
    guard !environment.isXCTestProcess else {
      return nil
    }
    return FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: identifier
    )
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

    if let baseRoot = resolveBaseRoot(using: environment, preferExternalDaemon: false) {
      return baseRoot
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
    Self.generatedCacheRoot(using: environment)
      .appendingPathComponent("thumbnails", isDirectory: true)
  }

  public static func notificationCacheRoot(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    Self.generatedCacheRoot(using: environment)
      .appendingPathComponent("notifications", isDirectory: true)
  }

  public static func migrateLegacyGeneratedCaches(
    using environment: HarnessMonitorEnvironment = .current,
    fileManager: FileManager = .default
  ) throws {
    try Self.prepareGeneratedCacheDirectory(
      Self.generatedCacheRoot(using: environment),
      cleaningLegacyDirectories: Self.legacyGeneratedCacheDirectories(using: environment),
      fileManager: fileManager
    )
  }

  /// Name of the marker file Spotlight honors to skip a directory tree.
  public static let nonIndexableMarkerName = ".metadata_never_index"

  /// Ensure the harness data root is excluded from Spotlight indexing and Time Machine backups.
  ///
  /// Writes an empty `.metadata_never_index` marker at the root (idempotent) and applies
  /// `isExcludedFromBackup`. Session workspaces, project caches, daemon DBs, and other
  /// high-churn generated artifacts live under this root and should never be indexed.
  public static func ensureHarnessRootNonIndexable(
    using environment: HarnessMonitorEnvironment = .current,
    fileManager: FileManager = .default
  ) throws {
    let root = Self.harnessRoot(using: environment)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    var mutableRoot = root
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try? mutableRoot.setResourceValues(resourceValues)

    let marker = root.appendingPathComponent(Self.nonIndexableMarkerName)
    if !fileManager.fileExists(atPath: marker.path) {
      try Data().write(to: marker, options: .atomic)
    }
  }

  public static func prepareGeneratedCacheDirectory(
    _ directory: URL,
    cleaningLegacyDirectories legacyDirectories: [URL] = [],
    fileManager: FileManager = .default
  ) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var mutableDirectory = directory
    try mutableDirectory.setResourceValues(resourceValues)

    let targetDirectory = directory.standardizedFileURL
    for legacyDirectory in legacyDirectories.map(\.standardizedFileURL)
    where
      legacyDirectory != targetDirectory
      && fileManager.fileExists(atPath: legacyDirectory.path)
    {
      try fileManager.removeItem(at: legacyDirectory)
    }
  }

  private static func legacyGeneratedCacheDirectories(
    using environment: HarnessMonitorEnvironment
  ) -> [URL] {
    let legacyCacheRoot = Self.harnessRoot(using: environment)
      .appendingPathComponent("cache", isDirectory: true)
    return [
      legacyCacheRoot.appendingPathComponent("thumbnails", isDirectory: true),
      legacyCacheRoot.appendingPathComponent("notifications", isDirectory: true),
    ]
  }

  public static var launchAgentPlistName: String {
    "io.harnessmonitor.daemon.plist"
  }

  public static var launchAgentBundleRelativePath: String {
    "Contents/Library/LaunchAgents/\(launchAgentPlistName)"
  }
}

extension HarnessMonitorPaths {
  public static func sessionsRoot(using env: HarnessMonitorEnvironment = .current) -> URL {
    harnessRoot(using: env).appendingPathComponent("sessions", isDirectory: true)
  }

  public static func sessionRoot(
    projectName: String,
    sessionId: String,
    using env: HarnessMonitorEnvironment = .current
  ) -> URL {
    sessionsRoot(using: env)
      .appendingPathComponent(projectName, isDirectory: true)
      .appendingPathComponent(sessionId, isDirectory: true)
  }

  public static func sessionWorktree(
    projectName: String,
    sessionId: String,
    using env: HarnessMonitorEnvironment = .current
  ) -> URL {
    sessionRoot(projectName: projectName, sessionId: sessionId, using: env)
      .appendingPathComponent("workspace", isDirectory: true)
  }

  public static func sessionShared(
    projectName: String,
    sessionId: String,
    using env: HarnessMonitorEnvironment = .current
  ) -> URL {
    sessionRoot(projectName: projectName, sessionId: sessionId, using: env)
      .appendingPathComponent("memory", isDirectory: true)
  }

  public static func socketDirectory(using env: HarnessMonitorEnvironment = .current) -> URL {
    let groupID = HarnessMonitorAppGroup.identifier
    let container = nativeAppGroupContainerURL(identifier: groupID, using: env)
    guard let group = container else {
      return harnessRoot(using: env).appendingPathComponent("sock", isDirectory: true)
    }
    return group.appendingPathComponent("sock", isDirectory: true)
  }
}

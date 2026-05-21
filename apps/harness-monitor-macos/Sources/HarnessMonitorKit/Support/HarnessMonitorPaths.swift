import CryptoKit
import Foundation

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
  /// 2. Explicit runtime lane (`HARNESS_MONITOR_RUNTIME_LANE`).
  /// 3. Cross-lane discovery: pick the live daemon whose ownership-scoped
  ///    manifest pid is alive. Lets Xcode IDE launches find the user's
  ///    externally-started daemon without baking a lane into the scheme.
  ///    Per-ownership: managed mode walks managed/ subtrees; external mode
  ///    walks external/ subtrees. Cross-checkout attach is preserved for
  ///    external mode.
  /// 4. Native group-container resolution for the configured or default app group id.
  /// 5. Home-relative app-group fallback via `HARNESS_APP_GROUP_ID`.
  /// 6. External-daemon legacy bypass (`HARNESS_MONITOR_EXTERNAL_DAEMON=1` or a
  ///    persisted external-mode preference injected into the environment):
  ///    returns `~/Library/Application Support` directly so explicit external
  ///    launches can stay symmetric with the legacy CLI-only layout after all
  ///    app-group and runtime-lane roots have been exhausted. Only evaluated
  ///    when `preferExternalDaemon` is true.
  ///
  /// Returns `nil` when none of the above resolves — callers decide how to handle that.
  static func resolveBaseRoot(
    using environment: HarnessMonitorEnvironment,
    preferExternalDaemon: Bool,
    discoverLiveDaemon: Bool = true
  ) -> URL? {
    let ownership = DaemonOwnership(environment: environment)

    if let configuredRoot = configuredDataHomeRoot(using: environment) {
      return configuredRoot
    }

    if let laneRoot = runtimeLaneBaseRoot(using: environment) {
      return laneRoot
    }

    if discoverLiveDaemon,
      let discoveredRoot = discoverLiveDaemonRoot(
        ownership: ownership,
        using: environment
      )
    {
      return discoveredRoot
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

    if preferExternalDaemon, ownership == .external {
      return environment.homeDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
    }

    return nil
  }

  static func sharedObservabilityRoot(
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

  public static func runtimeLane(
    using environment: HarnessMonitorEnvironment = .current
  ) -> String? {
    resolvedRuntimeLane(using: environment)
  }

  public static func codexBridgePort(
    using environment: HarnessMonitorEnvironment = .current
  ) -> Int? {
    guard let portValue = resolvedCodexBridgePortString(using: environment) else {
      return nil
    }
    return Int(portValue)
  }

  /// Launch-agent label for the bundled (managed) daemon.
  ///
  /// External daemons are not launchd-registered (they run from `harness
  /// daemon dev` in a user shell) so there's no symmetric label for them.
  ///
  /// The label MUST equal the bundled plist filename without its `.plist`
  /// extension — macOS 26's `SMAppService.register()` returns
  /// `error: 22 (EINVAL)` and `Service status: 3 (.notFound)` whenever the
  /// two diverge, which manifests as a managed-daemon bootstrap that loops
  /// on `Bootstrapping daemon client for managed daemon mode` without ever
  /// spawning a daemon process. Lane identity therefore flows through the
  /// `HARNESS_MONITOR_RUNTIME_LANE` env entry in the plist, not the label.
  ///
  /// For sandboxed SMAppService launch agents, the service name must be an
  /// immediate child of the app group. Keep this as
  /// `<app-group>.<single-component>` so backgroundtaskmanagementd can resolve
  /// the helper's full path instead of rejecting registration with a
  /// `job-creation` sandbox denial.
  public static func launchAgentLabel(
    using environment: HarnessMonitorEnvironment = .current
  ) -> String {
    if let explicitLabel = normalizedNonEmpty(
      environment.values[HarnessMonitorRuntimeLane.launchAgentLabelEnvKey]
    ) {
      return explicitLabel
    }
    return managedLaunchAgentLabelBase()
  }

  static func managedLaunchAgentLabelBase() -> String {
    HarnessMonitorRuntimeLane.launchAgentBaseLabel
  }

  /// The pre-coexistence label, used solely to find and unregister an
  /// orphaned legacy SMAppService entry on first launch under the new
  /// layout. Don't use for fresh registrations.
  public static func legacyManagedLaunchAgentLabel(
    using environment: HarnessMonitorEnvironment = .current
  ) -> String {
    guard let lane = resolvedRuntimeLane(using: environment) else {
      return HarnessMonitorRuntimeLane.launchAgentBaseLabel
    }
    return "\(HarnessMonitorRuntimeLane.launchAgentBaseLabel).\(lane)"
  }

  public static func commandEnvironmentVariables(
    using environment: HarnessMonitorEnvironment = .current
  ) -> [String: String] {
    Dictionary(uniqueKeysWithValues: commandEnvironmentEntries(using: environment))
  }

  public static func commandEnvironmentPrefix(
    using environment: HarnessMonitorEnvironment = .current
  ) -> String {
    commandEnvironmentEntries(using: environment)
      .map { "\($0.0)=\(shellEscape($0.1))" }
      .joined(separator: " ")
  }

  public static func shellCommand(
    _ command: String,
    using environment: HarnessMonitorEnvironment = .current
  ) -> String {
    let prefix = commandEnvironmentPrefix(using: environment)
    guard !prefix.isEmpty else {
      return command
    }
    return "\(prefix) \(command)"
  }

  public static func harnessRoot(using environment: HarnessMonitorEnvironment = .current) -> URL {
    harnessRoot(using: environment, discoverLiveDaemon: true)
  }

  static func harnessRootWithoutLiveDiscovery(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    harnessRoot(using: environment, discoverLiveDaemon: false)
  }

  static func harnessRoot(
    using environment: HarnessMonitorEnvironment,
    discoverLiveDaemon: Bool
  ) -> URL {
    if let base = resolveBaseRoot(
      using: environment,
      preferExternalDaemon: true,
      discoverLiveDaemon: discoverLiveDaemon
    ) {
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

    // Best-effort legacy fallback for explicit external-daemon launches after
    // every shared runtime/app-group root was unavailable.
    HarnessMonitorLogger.store.warning(
      "App group container unavailable; falling back to ~/Library/Application Support/harness"
    )
    return environment.homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("harness", isDirectory: true)
  }

  /// Daemon root for the current process's resolved [`DaemonOwnership`].
  /// Most existing call sites want this default. Pass explicit ownership
  /// when reading the OTHER side's state (rare; mostly for the coexistence
  /// status banner).
  public static func daemonRoot(using environment: HarnessMonitorEnvironment = .current) -> URL {
    daemonRoot(ownership: DaemonOwnership(environment: environment), using: environment)
  }

  static func daemonRootWithoutLiveDiscovery(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    harnessRootWithoutLiveDiscovery(using: environment)
      .appendingPathComponent("daemon", isDirectory: true)
      .appendingPathComponent(DaemonOwnership(environment: environment).rawValue, isDirectory: true)
  }

  /// Daemon root for an explicit ownership. Path:
  /// `<harnessRoot>/daemon/<ownership>/`.
  public static func daemonRoot(
    ownership: DaemonOwnership,
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    daemonRootBase(using: environment)
      .appendingPathComponent(ownership.rawValue, isDirectory: true)
  }

  /// Directory that contains the `managed/` and `external/` subtrees. Used
  /// when enumerating both sides or migrating legacy single-ownership state.
  public static func daemonRootBase(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
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

  public static func manifestURLWithoutLiveDiscovery(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    Self.daemonRootWithoutLiveDiscovery(using: environment)
      .appendingPathComponent("manifest.json")
  }

  public static func manifestURL(
    ownership: DaemonOwnership,
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    Self.daemonRoot(ownership: ownership, using: environment)
      .appendingPathComponent("manifest.json")
  }

  public static func authTokenURL(using environment: HarnessMonitorEnvironment = .current) -> URL {
    Self.daemonRoot(using: environment).appendingPathComponent("auth-token")
  }

  public static func authTokenURL(
    ownership: DaemonOwnership,
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    Self.daemonRoot(ownership: ownership, using: environment)
      .appendingPathComponent("auth-token")
  }

  public static func managedLaunchAgentBundleStampURL(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    Self.daemonRoot(ownership: .managed, using: environment)
      .appendingPathComponent("managed-launch-agent-bundle-stamp.json")
  }

  public static func managedLaunchAgentLockURL(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    Self.daemonRoot(ownership: .managed, using: environment)
      .appendingPathComponent("managed-launch-agent.lock")
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

  static func legacyGeneratedCacheDirectories(
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
    "\(HarnessMonitorRuntimeLane.launchAgentBaseLabel).plist"
  }

  /// Old plist filenames. Kept solely so the app can attempt to unregister
  /// orphaned SMAppService entries on first launch under the new layout.
  public static var legacyLaunchAgentPlistNames: [String] {
    [
      "io.harnessmonitor.daemon.managed.plist",
      "io.harnessmonitor.daemon.plist",
    ]
  }

  /// Pre-coexistence plist filename. Prefer `legacyLaunchAgentPlistNames` for
  /// cleanup; kept for callers/tests that still need the original singleton.
  public static var legacyLaunchAgentPlistName: String {
    "io.harnessmonitor.daemon.plist"
  }

  public static var launchAgentBundleRelativePath: String {
    "Contents/Library/LaunchAgents/\(launchAgentPlistName)"
  }
}

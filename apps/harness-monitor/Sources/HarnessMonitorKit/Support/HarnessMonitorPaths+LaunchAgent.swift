import Foundation

extension HarnessMonitorPaths {
  static func embeddedBundleValue(
    for key: String,
    using environment: HarnessMonitorEnvironment
  ) -> String? {
    guard let bundleURL = environment.bundleURL else {
      return nil
    }
    let bundle =
      bundleURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
      ? Bundle.main
      : Bundle(url: bundleURL)
    guard
      let rawValue = bundle?.object(forInfoDictionaryKey: key) as? String,
      rawValue.contains("$(") == false
    else {
      return nil
    }
    return normalizedNonEmpty(rawValue)
  }

  public static var launchAgentPlistName: String {
    launchAgentPlistName(using: .current)
  }

  public static func launchAgentPlistName(
    using environment: HarnessMonitorEnvironment
  ) -> String {
    "\(launchAgentLabel(using: environment)).plist"
  }

  /// Old plist filenames. Kept solely so the app can attempt to unregister
  /// orphaned SMAppService entries on first launch under the new layout.
  public static var legacyLaunchAgentPlistNames: [String] {
    [
      "Q498EB36N4.io.harnessmonitor.agent.plist",
      "Q498EB36N4.io.harnessmonitor.daemon.plist",
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
    launchAgentBundleRelativePath(using: .current)
  }

  public static func launchAgentBundleRelativePath(
    using environment: HarnessMonitorEnvironment
  ) -> String {
    "Contents/Library/LaunchAgents/\(launchAgentPlistName(using: environment))"
  }

  public static func managedLaunchAgentBundleStampURL(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    managedLaunchAgentControlRoot(using: environment)
      .appendingPathComponent("managed-launch-agent-bundle-stamp.json")
  }

  public static func managedLaunchAgentLockURL(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    managedLaunchAgentControlRoot(using: environment)
      .appendingPathComponent("managed-launch-agent.lock")
  }

  public static func legacyManagedLaunchAgentLockURL(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    appGroupHarnessRoot(using: environment)
      .appendingPathComponent("managed-launch-agents", isDirectory: true)
      .appendingPathComponent("legacy-cleanup.lock")
  }

  static func managedLaunchAgentControlRoot(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    appGroupHarnessRoot(using: environment)
      .appendingPathComponent("managed-launch-agents", isDirectory: true)
      .appendingPathComponent(launchAgentLabel(using: environment), isDirectory: true)
  }
}

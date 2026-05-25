import Foundation

extension HarnessMonitorPaths {
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

import Foundation

extension DaemonController {
  func refreshManagedLaunchAgentIfBundledHelperChanged() throws -> Bool {
    guard ownership == .managed else {
      return false
    }
    guard launchAgentManager.registrationState() == .enabled else {
      return false
    }
    guard let currentStamp = try managedLaunchAgentCurrentBundleStamp() else {
      return false
    }

    let stampURL = HarnessMonitorPaths.managedLaunchAgentBundleStampURL(using: environment)
    guard let persistedStamp = loadManagedLaunchAgentBundleStamp(from: stampURL) else {
      try persistManagedLaunchAgentBundleStamp(currentStamp, to: stampURL)
      return false
    }
    guard persistedStamp != currentStamp else {
      return false
    }

    HarnessMonitorLogger.lifecycle.notice(
      "Bundled managed daemon helper changed; refreshing launch agent before warm-up"
    )
    try refreshManagedLaunchAgent(currentStamp: currentStamp)
    return true
  }

  func refreshManagedLaunchAgent(currentStamp: ManagedLaunchAgentBundleStamp) throws {
    let stampURL = HarnessMonitorPaths.managedLaunchAgentBundleStampURL(using: environment)
    try launchAgentManager.unregister()
    clearManagedLaunchAgentBundleStamp(at: stampURL)
    try launchAgentManager.register()
    if launchAgentManager.registrationState() == .enabled {
      try persistManagedLaunchAgentBundleStamp(currentStamp, to: stampURL)
    }
  }

  func persistCurrentManagedLaunchAgentBundleStamp() throws {
    guard let currentStamp = try managedLaunchAgentCurrentBundleStamp() else {
      return
    }
    try persistManagedLaunchAgentBundleStamp(
      currentStamp,
      to: HarnessMonitorPaths.managedLaunchAgentBundleStampURL(using: environment)
    )
  }

  func loadManagedLaunchAgentBundleStamp(from url: URL) -> ManagedLaunchAgentBundleStamp? {
    guard let data = FileManager.default.contents(atPath: url.path) else {
      return nil
    }
    return try? JSONDecoder().decode(ManagedLaunchAgentBundleStamp.self, from: data)
  }

  func persistManagedLaunchAgentBundleStamp(
    _ stamp: ManagedLaunchAgentBundleStamp,
    to url: URL
  ) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(stamp)
    try data.write(to: url, options: .atomic)
  }

  func clearManagedLaunchAgentBundleStamp() {
    clearManagedLaunchAgentBundleStamp(
      at: HarnessMonitorPaths.managedLaunchAgentBundleStampURL(using: environment)
    )
  }

  func clearManagedLaunchAgentBundleStamp(at url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}

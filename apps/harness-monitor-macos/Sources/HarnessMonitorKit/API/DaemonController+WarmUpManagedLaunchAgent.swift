import Foundation

actor ManagedLaunchAgentDeferredRefreshState {
  private var pendingStamp: ManagedLaunchAgentBundleStamp?

  func setPending(_ stamp: ManagedLaunchAgentBundleStamp) {
    pendingStamp = stamp
  }

  func takePending() -> ManagedLaunchAgentBundleStamp? {
    defer { pendingStamp = nil }
    return pendingStamp
  }

  func clear() {
    pendingStamp = nil
  }
}

extension DaemonController {
  func managedLaunchAgentRefreshNeededForBundledHelperChange()
    throws -> ManagedLaunchAgentBundleStamp?
  {
    guard ownership == .managed else {
      return nil
    }
    guard launchAgentManager.registrationState() == .enabled else {
      return nil
    }
    guard let currentStamp = try managedLaunchAgentCurrentBundleStamp() else {
      return nil
    }

    let stampURL = HarnessMonitorPaths.managedLaunchAgentBundleStampURL(using: environment)
    guard let persistedStamp = loadManagedLaunchAgentBundleStamp(from: stampURL) else {
      try persistManagedLaunchAgentBundleStamp(currentStamp, to: stampURL)
      return nil
    }
    guard persistedStamp != currentStamp else {
      return nil
    }

    return currentStamp
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

  func queueDeferredManagedLaunchAgentRefresh(_ stamp: ManagedLaunchAgentBundleStamp) async {
    await managedLaunchAgentDeferredRefreshState.setPending(stamp)
  }

  func clearDeferredManagedLaunchAgentRefresh() async {
    await managedLaunchAgentDeferredRefreshState.clear()
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

  func managedLaunchAgentDeferredRefreshCandidate(
    for manifest: DaemonManifest,
    state: inout WarmUpLoopState
  ) throws -> ManagedLaunchAgentBundleStamp? {
    guard ownership == .managed else {
      state.pendingBundleStampRefresh = nil
      return nil
    }
    if let pendingRefresh = state.pendingBundleStampRefresh {
      let currentStamp = try managedLaunchAgentCurrentBundleStamp()
      let publishedStamp = manifest.binaryStamp?.managedLaunchAgentBundleStamp
      if publishedStamp == currentStamp {
        state.pendingBundleStampRefresh = nil
        return nil
      }
      return pendingRefresh
    }
    guard launchAgentManager.registrationState() == .enabled else {
      return nil
    }
    guard
      let publishedStamp = manifest.binaryStamp?.managedLaunchAgentBundleStamp,
      let currentStamp = try managedLaunchAgentCurrentBundleStamp(),
      publishedStamp != currentStamp
    else {
      return nil
    }
    return currentStamp
  }

  func refreshManagedLaunchAgentAfterManifestLoadFailureIfNeeded(
    error: DaemonControlError,
    state: inout WarmUpLoopState
  ) throws -> Bool {
    switch error {
    case .manifestMissing, .manifestUnreadable:
      break
    default:
      return false
    }
    return try refreshManagedLaunchAgentForPendingBundledHelperChangeIfNeeded(state: &state)
  }

  func refreshManagedLaunchAgentForPendingBundledHelperChangeIfNeeded(
    state: inout WarmUpLoopState
  ) throws -> Bool {
    guard ownership == .managed else {
      return false
    }
    guard state.refreshedManagedLaunchAgentDuringWarmUp == false else {
      return false
    }
    guard let currentStamp = state.pendingBundleStampRefresh else {
      return false
    }
    HarnessMonitorLogger.lifecycle.notice(
      "Bundled managed daemon helper changed and no healthy daemon is available; refreshing launch agent"
    )
    try refreshManagedLaunchAgent(currentStamp: currentStamp)
    state.pendingBundleStampRefresh = nil
    state.refreshedManagedLaunchAgentDuringWarmUp = true
    return true
  }
}

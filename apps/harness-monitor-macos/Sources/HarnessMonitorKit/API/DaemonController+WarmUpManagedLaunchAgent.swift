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

    switch currentManagedLaunchAgentOwnership() {
    case .ownedByLiveSibling:
      // A sibling Monitor instance is currently the launch-agent owner.
      // Defer the refresh decision to that owner so two Monitor processes
      // never race on `unregister`/`register` for the shared
      // `io.harnessmonitor.daemon` lane.
      return nil
    case .staleOwnership:
      // Marker survived a previous instance's hard exit. Reclaim it now
      // so subsequent calls don't keep treating the dead PID as live.
      clearManagedLaunchAgentOwner()
    case .unowned, .ownedBySelf:
      break
    }

    return currentStamp
  }

  func refreshManagedLaunchAgent(
    currentStamp: ManagedLaunchAgentBundleStamp
  ) throws -> ManagedLaunchAgentRefreshDecision {
    guard ownership == .managed else {
      // Defense in depth: predicate methods already gate on
      // `.managed`, but `refreshManagedLaunchAgent` should never
      // operate on an external daemon lane regardless of caller.
      return .skippedNotManagedDaemon
    }
    switch currentManagedLaunchAgentOwnership() {
    case .ownedByLiveSibling(let owner):
      HarnessMonitorLogger.lifecycle.warning(
        """
        Refusing managed launch-agent refresh: another live Monitor instance \
        owns io.harnessmonitor.daemon. \
        sibling_pid=\(owner.pid, privacy: .public) \
        sibling_executable=\(owner.executablePath, privacy: .public) \
        registered_at=\(owner.registeredAt.timeIntervalSince1970, privacy: .public). \
        Set HARNESS_MONITOR_RUNTIME_PROFILE on this build to claim a \
        separate lane.
        """
      )
      return .skippedSiblingOwnsLane(owner)
    case .staleOwnership:
      // Owner record survived a hard exit; reclaim before refreshing
      // so the next register writes an authoritative marker.
      clearManagedLaunchAgentOwner()
    case .unowned, .ownedBySelf:
      break
    }

    let stampURL = HarnessMonitorPaths.managedLaunchAgentBundleStampURL(using: environment)
    try launchAgentManager.unregister()
    clearManagedLaunchAgentBundleStamp(at: stampURL)
    clearManagedLaunchAgentOwner()
    try launchAgentManager.register()
    if launchAgentManager.registrationState() == .enabled {
      try persistManagedLaunchAgentBundleStamp(currentStamp, to: stampURL)
      try persistCurrentManagedLaunchAgentOwner()
    }
    return .refreshed
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
      return pendingRefresh
    }
    guard launchAgentManager.registrationState() == .enabled else {
      return nil
    }
    guard
      let currentStamp = try managedLaunchAgentCurrentBundleStamp(),
      currentStamp.matchesPublishedDaemonBinaryStamp(manifest.binaryStamp) == false
    else {
      return nil
    }
    switch currentManagedLaunchAgentOwnership() {
    case .ownedByLiveSibling:
      // Same hermetic rule as the synchronous helper: never queue a
      // deferred refresh while a sibling Monitor owns the launch agent.
      return nil
    case .staleOwnership:
      clearManagedLaunchAgentOwner()
    case .unowned, .ownedBySelf:
      break
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
      """
      Bundled managed daemon launch-agent assets changed and no healthy \
      daemon is available; refreshing launch agent
      """
    )
    switch try refreshManagedLaunchAgent(currentStamp: currentStamp) {
    case .refreshed:
      state.pendingBundleStampRefresh = nil
      state.refreshedManagedLaunchAgentDuringWarmUp = true
      return true
    case .skippedSiblingOwnsLane, .skippedNotManagedDaemon:
      // A sibling Monitor owns the lane (or this is not a managed
      // daemon). Leave the pending stamp queued so the next warm-up
      // tick can re-evaluate without us claiming we refreshed.
      return false
    }
  }
}

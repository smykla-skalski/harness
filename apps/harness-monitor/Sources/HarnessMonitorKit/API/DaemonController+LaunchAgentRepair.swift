import Foundation

extension DaemonController {
  /// Tear down and re-register the bundled SMAppService launch agent at app
  /// launch ONLY when the helper bundle on disk no longer matches the stamp
  /// we persisted on the last successful register — that's the signal an
  /// Xcode rebuild (or any external mutation) shifted the helper's
  /// `cs_mtime` while BTM cached the prior code identity. Without a refresh
  /// the next `xpcproxy` spawn hits `exit(78)` / "Unable to get updated
  /// LWCR" because the on-disk binary's identity doesn't match BTM's
  /// disposition record.
  ///
  /// Skips when:
  /// - ownership is `.external` (`harness daemon dev` lifecycle)
  /// - the persisted stamp matches the current helper (no rebuild — the
  ///   live daemon is healthy and tearing it down would just bounce every
  ///   sibling WS for no gain)
  /// - a live sibling Monitor instance owns the lane (defer to its
  ///   refresh decision; matches `managedLaunchAgentRefreshNeededFor…`'s
  ///   ownership snapshot gate)
  ///
  /// Returns `true` when a refresh ran, `false` when skipped.
  public func refreshManagedLaunchAgentForLaunch() async throws -> Bool {
    guard ownership == .managed else {
      return false
    }
    let preState = launchAgentManager.registrationState()
    guard preState == .enabled || preState == .requiresApproval else {
      // Nothing currently registered — the regular bootstrap path will
      // call `registerLaunchAgent()` itself and that fresh register
      // writes a clean BTM record. No tear-down needed here.
      return false
    }

    // Stamp gate: only tear down when the bundled helper actually
    // changed since the last successful register. Without this, every
    // launch unregisters a healthy daemon and bounces any sibling WS.
    guard let currentStamp = try? managedLaunchAgentCurrentBundleStamp() else {
      return false
    }
    let stampURL = HarnessMonitorPaths.managedLaunchAgentBundleStampURL(
      using: environment
    )
    if let persistedStamp = loadManagedLaunchAgentBundleStamp(from: stampURL),
      persistedStamp == currentStamp
    {
      return false
    }

    // Sibling-lane gate: defer to the owner instance if another live
    // Monitor process registered this lane. Mirrors the gate in
    // `managedLaunchAgentRefreshNeededForBundledHelperChange`.
    switch currentManagedLaunchAgentOwnership() {
    case .ownedByLiveSibling(let owner):
      HarnessMonitorLogger.lifecycle.notice(
        """
        Skipping on-launch managed daemon refresh: lane owned by live sibling \
        pid \(owner.pid, privacy: .public). Helper change will be picked up \
        when the sibling refreshes.
        """
      )
      return false
    case .staleOwnership:
      clearManagedLaunchAgentOwner()
    case .unowned, .ownedBySelf:
      break
    }

    try launchAgentManager.unregister()
    clearManagedLaunchAgentBundleStamp(at: stampURL)
    clearManagedLaunchAgentOwner()
    // BTM needs a moment after `unregister()` to evict the prior
    // disposition record; without this delay the immediate `register()`
    // can land on a half-cleared row and the next launchd spawn still
    // fails to fetch the updated LWCR.
    try? await Task.sleep(for: .milliseconds(500))

    try launchAgentManager.register()
    let postState = launchAgentManager.registrationState()
    switch postState {
    case .enabled:
      try persistManagedLaunchAgentBundleStamp(currentStamp, to: stampURL)
      try persistCurrentManagedLaunchAgentOwner()
      HarnessMonitorLogger.lifecycle.notice(
        "Refreshed managed launch agent on launch after helper bundle stamp change"
      )
      return true
    case .requiresApproval:
      HarnessMonitorLogger.lifecycle.notice(
        "Managed launch agent refresh awaiting user approval in System Settings"
      )
      return true
    case .notRegistered, .notFound:
      throw DaemonControlError.commandFailed(
        "launch agent refresh did not complete"
      )
    }
  }

  /// Force re-registration of the SMAppService launch agent to recover from
  /// stale BTM uuid records (xpcproxy `EX_CONFIG` spawn-fail loops). Always
  /// unregisters first, regardless of `ownership`, so external-daemon users
  /// can clean up an orphan managed registration without changing modes.
  /// In `.managed` mode the unregister is followed by a fresh register so
  /// the helper is reachable again on the next launchd spawn cycle.
  public func repairLaunchAgentRegistration() async throws -> String {
    let preState = launchAgentManager.registrationState()
    switch preState {
    case .enabled, .requiresApproval:
      try launchAgentManager.unregister()
      clearManagedLaunchAgentBundleStamp()
      clearManagedLaunchAgentOwner()
    case .notRegistered, .notFound:
      break
    }

    guard ownership == .managed else {
      return preState == .notRegistered || preState == .notFound
        ? "launch agent not registered"
        : "launch agent unregistered"
    }

    try launchAgentManager.register()
    let postState = launchAgentManager.registrationState()
    if postState == .enabled {
      try persistCurrentManagedLaunchAgentBundleStamp()
      try persistCurrentManagedLaunchAgentOwner()
      return "launch agent re-registered"
    }
    if postState == .requiresApproval {
      return "launch agent re-registered; approval required in System Settings"
    }
    throw DaemonControlError.commandFailed(
      "launch agent re-registration did not complete"
    )
  }
}

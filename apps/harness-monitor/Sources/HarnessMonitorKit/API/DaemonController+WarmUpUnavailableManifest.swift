import Foundation

extension DaemonController {
  func managedUnavailableManifestOutcome(
    after error: DaemonControlError,
    state: inout WarmUpLoopState
  ) -> WarmUpIterationOutcome? {
    switch error {
    case .manifestMissing, .manifestUnreadable:
      break
    default:
      return nil
    }
    guard
      ownership == .managed,
      launchAgentManager.registrationState() == .enabled
    else {
      return nil
    }

    // A daemon takes this lock before it can publish a manifest. Missing
    // manifest evidence is therefore inconclusive while the lock is held;
    // start a fresh grace period if that boot attempt later exits silently.
    guard daemonSingletonLockIsHeld() == false else {
      state.managedStaleManifestTracker.reset()
      return .continueLoop
    }

    // The sibling captured at warm-up entry may exit before publishing its
    // manifest. Re-read on each unavailable observation once the daemon lock
    // is free so that ownership does not pin the caller to the full timeout.
    state.ownerSnapshot = currentOwnerSnapshot()
    switch state.ownerSnapshot.ownership {
    case .ownedBySelf:
      // A registration created by this process can still be waiting for
      // launchd or running startup work before it takes the daemon lock.
      state.managedStaleManifestTracker.reset()
      return .continueLoop
    case .ownedByLiveSibling:
      // The sibling owns both the lane and any recovery decision. Returning
      // the error early would make the store tear down its live registration.
      state.managedStaleManifestTracker.reset()
      return .continueLoop
    case .staleOwnership:
      clearManagedLaunchAgentOwner()
      state.ownerSnapshot = currentOwnerSnapshot()
    case .unowned:
      break
    }

    let manifestPath = HarnessMonitorPaths.manifestURL(using: environment).path
    let signature = "managed-manifest-unavailable|\(manifestPath)"
    let observation = state.managedStaleManifestTracker.observe(
      signature: signature,
      now: ContinuousClock.now,
      gracePeriod: managedStaleManifestGracePeriod
    )
    switch observation {
    case .expired:
      return stopForUnavailableManagedManifest(
        error,
        manifestPath: manifestPath,
        state: &state
      )
    case .freshSignature, .withinGrace:
      return observation == .freshSignature ? .progressedLoop : .continueLoop
    }
  }

  private func stopForUnavailableManagedManifest(
    _ error: DaemonControlError,
    manifestPath: String,
    state: inout WarmUpLoopState
  ) -> WarmUpIterationOutcome {
    if daemonSingletonLockIsHeld() {
      state.managedStaleManifestTracker.reset()
      return .continueLoop
    }
    // Ownership may have changed during the grace period. Re-read it at the
    // destructive decision boundary so a newly live sibling remains owner.
    state.ownerSnapshot = currentOwnerSnapshot()
    switch state.ownerSnapshot.ownership {
    case .ownedBySelf, .ownedByLiveSibling:
      state.managedStaleManifestTracker.reset()
      return .continueLoop
    case .staleOwnership:
      clearManagedLaunchAgentOwner()
      state.ownerSnapshot = currentOwnerSnapshot()
    case .unowned:
      break
    }
    state.immediateError = error
    let gracePeriod = String(describing: managedStaleManifestGracePeriod)
    HarnessMonitorLogger.lifecycle.error(
      """
      Managed daemon manifest remained unavailable at \
      \(manifestPath, privacy: .public) for \(gracePeriod, privacy: .public)
      """
    )
    return .stopLoop
  }
}

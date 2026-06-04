import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasViewModel {
  /// Capture a snapshot of the in-progress canvas state at the moment a daemon
  /// round-trip rejects. The user may have typed 200-2000ms between the
  /// `snapshotState()` taken pre-await and the reject landing; without this
  /// buffer those edits vanish when `restoreState(_:)` writes the pre-save
  /// snapshot back. Calling sites pair `captureRecoveryBuffer()` with
  /// `restoreState(_:)`: rebase semantics are deferred (the daemon API has no
  /// rebase primitive), so the user gets a "Recover" affordance instead.
  ///
  /// Recovery presence flips the observed `hasRecoverableEdits` bit so the
  /// chrome can light up a toast without subscribing to the snapshot payload
  /// itself.
  func captureRecoveryBuffer() {
    let snapshot = PolicyCanvasSnapshot(
      nodes: nodes,
      groups: groups,
      edges: edges,
      selection: selection,
      latestSimulation: latestSimulation,
      routingHints: routingHints
    )
    lastRejectedRecovery = snapshot
    hasRecoverableEdits = true
  }

  /// Restore the canvas to the recovery snapshot captured at the last reject.
  /// Returns false when there is nothing to recover (UI gates this on
  /// `hasRecoverableEdits`, but defensive guards keep the affordance from
  /// double-firing). On success, the document is marked dirty (the user
  /// expects to save the recovered state themselves) and the recovery slot is
  /// cleared so a second click can't re-apply a stale buffer.
  ///
  /// Autosave decompensation state (consecutive failures, `.disabled`) is
  /// preserved: recovery does not prove the daemon is healthy, it only
  /// restores user-typed edits. The user still has to hit Save to validate
  /// the round-trip.
  @discardableResult
  func recoverRejectedEdits() -> Bool {
    guard let recovery = lastRejectedRecovery else {
      return false
    }
    nodes = recovery.nodes
    groups = recovery.groups
    edges = recovery.edges
    selection = recovery.selection
    latestSimulation = recovery.latestSimulation
    routingHints = recovery.routingHints
    reconcileGroupFrames()
    // Arm one-shot autosave suppression so the upcoming dirty flip (from the
    // restore writes) does not immediately fire an autosave with state the
    // daemon hasn't seen — the user explicitly chose Recover, they decide
    // when to retry the save.
    autosaveSuppressed = true
    documentDirty = true
    clearTransientGestureState()
    invalidateValidationCache()
    clearRecoveryBuffer()
    notifyStatus("Recovered unsaved edits")
    return true
  }

  /// Drop the recovery snapshot without applying it. Called from the dismiss
  /// affordance on the recovery toast and after a successful save (the
  /// previous reject's recovery state is no longer relevant).
  func clearRecoveryBuffer() {
    lastRejectedRecovery = nil
    hasRecoverableEdits = false
  }
}

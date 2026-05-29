import HarnessMonitorKit
import SwiftUI

extension PolicyCanvasView {
  /// Shared save flow used by both the manual Save button and the debounced
  /// autosave task. `reason` distinguishes the two so the outcome surface
  /// (`lastAutosaveOutcome`) is only touched on the autosave path — manual
  /// saves do not pretend to be the last autosave attempt.
  enum SaveReason {
    case manualSave
    case autosave
  }

  func saveDraft() {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    // Foreground save races autosave when both fire close together (e.g.
    // user types, autosave schedules, user clicks Save before the 1.5s
    // window elapses). `beginForegroundSave()` cancels the pending autosave
    // task AND flips `isSavingDraft` synchronously so an autosave wake
    // landing between this call and the Task body's first await bails at
    // the in-flight guard. The defer in `performSave` calls
    // `endForegroundSave()` to clear the flag.
    performSave(reason: .manualSave)
  }

  func simulate() {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    // `beginForegroundSave` is autosave-specific; simulate uses its own
    // in-flight flag but should still cancel the pending autosave for the
    // same race-window reason. Set `isSimulating` synchronously here
    // (before the Task spawns) for symmetry with the save path.
    viewModel.cancelAutosave()
    let snapshot = viewModel.snapshotState()
    let document = viewModel.exportDocument()
    viewModel.isSimulating = true
    Task { @MainActor in
      defer { viewModel.isSimulating = false }
      let simulated = await store?.simulateTaskBoardPolicyPipeline(document: document) ?? false
      if simulated {
        await forceReloadPolicyPipeline()
      } else {
        viewModel.restoreState(snapshot, reason: "Simulation rejected, restored previous canvas")
      }
    }
  }

  func performSave(reason: SaveReason) {
    // Local pre-flight runs before snapshot so the user gets fast feedback on
    // cycles + orphans. Soft warning only - daemon is authoritative, and the
    // snapshot/restore frame around exportDocument() handles rollback on
    // daemon rejection.
    _ = viewModel.runLocalPreflight()
    let snapshot = viewModel.snapshotState()
    let document = viewModel.exportDocument()
    // Deferred (tracking-id P3I.3): saveTaskBoardPolicyPipelineDraft returns
    // Bool, which conflates transport failure (IPC error / daemon process
    // died) with semantic rejection (daemon parsed and said no). Both flow
    // into the same restoreState path here. Transport failures should retry
    // with exponential backoff and preserve local state; semantic rejections
    // should restore as today. The store interface lives in HarnessMonitorKit
    // and is shared with other surfaces, so widening it to a typed
    // AutosaveOutcome (accepted / rejected(reason:) / transportFailure) is
    // deferred to a follow-up wave. Until then, the failure ceiling (item 1)
    // bounds the worst-case decompensation: three rejects of any kind flip
    // the subsystem to .disabled and surface a sticky affordance.
    viewModel.beginForegroundSave()
    Task { @MainActor in
      defer { viewModel.endForegroundSave() }
      let saved = await store?.saveTaskBoardPolicyPipelineDraft(document: document) ?? false
      if saved {
        if reason == .autosave {
          viewModel.markAutosaveSucceeded()
        } else {
          // Manual save clears the consecutive-failure counter and exits the
          // .disabled state so the next dirty flip can resume autosave.
          viewModel.markManualSaveSucceeded()
        }
        // Adopt the saved revision as the clean backing in place. The live
        // graph already shows the saved content, so re-point backing without a
        // reload (no viewport recenter, no undo wipe) and record the revision
        // as our own so the daemon's echo is never read as a remote change.
        // resolveSuccessfulSave keeps the canvas dirty when the user edited
        // during the round-trip; endForegroundSave then re-arms the follow-up
        // save once isSavingDraft clears. A full refresh is intentionally not
        // run here — the store already refreshed the active-canvas summary, and
        // re-applying a re-serialized daemon document would rebuild the graph
        // and recenter the viewport on every save.
        _ = viewModel.resolveSuccessfulSave(savedDocument: document)
      } else {
        // Capture in-progress edits the user may have typed during the
        // 200-2000ms round-trip BEFORE restoring to the pre-save snapshot
        // - otherwise the rollback below silently throws those edits away
        // and the user re-discovers them missing the next time they look.
        viewModel.captureRecoveryBuffer()
        if reason == .autosave {
          viewModel.markAutosaveFailed()
        }
        // Daemon rejected the save; roll local state back to the pre-save
        // snapshot so the chrome and graph reflect what the daemon still
        // believes is the truth. restoreState funnels the status string
        // through one notify call so the inspector line is not racing a
        // second-write override that distorts the user-visible reason.
        // restoreState arms one-shot autosave suppression so the rollback's
        // dirty-write does not re-trigger the same rejected save.
        let rollbackReason =
          reason == .autosave
          ? "Autosave rejected, restored previous canvas"
          : "Save rejected, restored previous canvas"
        viewModel.restoreState(snapshot, reason: rollbackReason)
      }
    }
  }

  func requestPromote() {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    guard viewModel.canPromote, let revision = viewModel.backingDocument?.revision else {
      statusLine = "Promote requires a saved matching simulation"
      return
    }
    statusLine = "Confirm promotion for revision \(revision)"
    isShowingPromoteConfirmation = true
  }

  func confirmPromote() {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    guard viewModel.canPromote, let revision = viewModel.backingDocument?.revision else {
      statusLine = "Promote requires a saved matching simulation"
      return
    }
    viewModel.isPromoting = true
    Task { @MainActor in
      defer { viewModel.isPromoting = false }
      let promoted = await store?.promoteTaskBoardPolicyPipeline(revision: revision) ?? false
      if promoted {
        await forceReloadPolicyPipeline()
      } else {
        statusLine = "Promotion blocked"
      }
    }
  }

  func forceReloadPolicyPipeline() async {
    guard let store else {
      return
    }
    await store.bootstrapIfNeeded()
    await store.refreshTaskBoardPolicyPipeline()
    applyDashboardSnapshot()
  }

  func applyDashboardSnapshot() {
    let snapshot = dashboardSnapshot
    if snapshot.activeCanvasId != viewModel.activeCanvasId && !viewModel.documentDirty {
      viewModel.applyDocument(
        document: snapshot.document,
        simulation: snapshot.simulation,
        audit: snapshot.audit,
        activeCanvasId: snapshot.activeCanvasId,
        forceDocumentReload: true
      )
      return
    }
    viewModel.load(
      document: snapshot.document,
      simulation: snapshot.simulation,
      audit: snapshot.audit,
      activeCanvasId: snapshot.activeCanvasId
    )
  }

  func enforceCanvasAutomationPolicies() {
    let compilation = viewModel.automationPolicyCompilation
    guard !compilation.policies.isEmpty || automationPolicyCenter.document.hasCanvasPolicies else {
      statusLine = "Add a canvas source node before enforcing automation policies"
      return
    }
    automationPolicyCenter.replaceCanvasPolicies(compilation.policies)
    statusLine =
      compilation.policies.isEmpty
      ? "Cleared enforced canvas automation policies"
      : "Enforced \(compilation.summaryText.lowercased())"
  }

  /// Kick off a save when the scene is about to drop to background. macOS does
  /// not guarantee the save completes before the scene tears down, but the
  /// Task spawns on the MainActor synchronously and starts the daemon
  /// round-trip before scenePhase finishes its transition. The defer in
  /// `performSave` keeps `isSavingDraft` correct even if the scene dies
  /// mid-await. Suppression: do not flush when `lastAutosaveOutcome ==
  /// .disabled` (the user has already been asked to save manually, surprising
  /// them with a background save on top would compete with their next manual
  /// attempt).
  func flushPendingAutosaveBeforeBackground() {
    if case .disabled = viewModel.lastAutosaveOutcome {
      return
    }
    performSave(reason: .autosave)
  }

  /// User clicked the "Recover" toast button. Apply the recovery buffer
  /// captured at the last reject. No-op when there is nothing to recover.
  func recoverRejectedEdits() {
    _ = viewModel.recoverRejectedEdits()
  }
}

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
    // Foreground save races autosave when both fire close together (e.g.
    // user types, autosave schedules, user clicks Save before the 1.5s
    // window elapses). Cancel the pending autosave task first so its
    // delayed save doesn't land after our reload with a stale revision.
    viewModel.cancelAutosave()
    performSave(reason: .manualSave)
  }

  func simulate() {
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
    // cycles + orphans. Soft warning only — daemon is authoritative, and the
    // snapshot/restore frame around exportDocument() handles rollback on
    // daemon rejection.
    _ = viewModel.runLocalPreflight()
    let snapshot = viewModel.snapshotState()
    let document = viewModel.exportDocument()
    viewModel.isSavingDraft = true
    Task { @MainActor in
      defer { viewModel.isSavingDraft = false }
      let saved = await store?.saveTaskBoardPolicyPipelineDraft(document: document) ?? false
      if saved {
        if reason == .autosave {
          viewModel.markAutosaveSucceeded()
        }
        // Don't pre-clear documentDirty across the upcoming await. MainActor
        // serializes turns, not the gap between awaits: a dashboard publish
        // running between the clear and the refresh's return would take the
        // clean branch and clobber edits the user made during the save. Let
        // load() clear dirty when the post-save refresh applies the new
        // backingDocument on its own clean-incoming branch.
        await forceReloadPolicyPipeline()
      } else {
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
    guard viewModel.canPromote, let revision = viewModel.backingDocument?.revision else {
      statusLine = "Promote requires a saved matching simulation"
      return
    }
    statusLine = "Confirm promotion for revision \(revision)"
    isShowingPromoteConfirmation = true
  }

  func confirmPromote() {
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
    await store.refreshTaskBoardPolicyPipeline()
    applyDashboardSnapshot()
  }

  func applyDashboardSnapshot() {
    viewModel.load(
      document: dashboardUI?.taskBoardPolicyPipeline,
      simulation: dashboardUI?.taskBoardPolicySimulation,
      audit: dashboardUI?.taskBoardPolicyAudit
    )
  }
}

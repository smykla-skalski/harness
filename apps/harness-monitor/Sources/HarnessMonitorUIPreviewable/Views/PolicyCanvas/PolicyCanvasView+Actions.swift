import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import OSLog
import SwiftUI

private let policyCanvasSaveSignposter = OSSignposter(
  subsystem: "io.harnessmonitor",
  category: "policy-canvas.perf"
)

extension PolicyCanvasView {
  /// Shared save flow used by both the manual Save button and the debounced
  /// autosave task. `reason` distinguishes the two so the outcome surface
  /// (`lastAutosaveOutcome`) is only touched on the autosave path — manual
  /// saves do not pretend to be the last autosave attempt.
  typealias SaveReason = PolicyCanvasDraftSaveReason

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
      let simulated = await runtime?.simulatePolicyCanvas(document: document) ?? false
      if simulated {
        await forceReloadPolicyPipeline()
        viewModel.flashHealthyWorkflowStatusStagesAfterSimulation(
          remoteActionsEnabled: remoteActionsEnabled
        )
      } else {
        viewModel.restoreState(snapshot, reason: "Simulation rejected, restored previous canvas")
      }
    }
  }

  func performSave(reason: SaveReason) {
    let transaction = viewModel.beginDraftSaveTransaction()
    let canvasIdentifier = runtime?.policyCanvasSnapshot.activeCanvasId ?? "missing"
    // Deferred (tracking-id P3I.3): saveTaskBoardPolicyPipelineDraft now returns
    // the saved document (or nil), so the daemon's bumped revision is adopted
    // below — but nil still conflates transport failure (IPC error / daemon
    // process died) with semantic rejection (daemon parsed and said no). Both
    // flow into the same restoreState path here. Transport failures should
    // retry with exponential backoff and preserve local state; semantic
    // rejections should restore as today. Widening nil to a typed
    // AutosaveOutcome (accepted / rejected(reason:) / transportFailure) is
    // deferred to a follow-up wave. Until then, the failure ceiling (item 1)
    // bounds the worst-case decompensation: three rejects of any kind flip
    // the subsystem to .disabled and surface a sticky affordance.
    setRuntimePolicyCanvasActionInFlight(true)
    HarnessMonitorAsyncWorkQueue.shared.submit(
      HarnessMonitorAsyncWorkQueue.WorkItem(title: "Saving policy canvas") {
        let localPreflightErrorCount = await transaction.runLocalPreflight()
        if localPreflightErrorCount > 0 {
          await MainActor.run {
            viewModel.notifyStatus(
              "Local validation warning - \(localPreflightErrorCount) issue(s); daemon will check"
            )
          }
        }
        let exportSignpostID = policyCanvasSaveSignposter.makeSignpostID()
        let exportInterval = policyCanvasSaveSignposter.beginInterval(
          "policy_canvas.save.export",
          id: exportSignpostID
        )
        let document = transaction.exportDocument()
        policyCanvasSaveSignposter.endInterval(
          "policy_canvas.save.export",
          exportInterval,
          "nodes=\(document.nodes.count, privacy: .public) edges=\(document.edges.count, privacy: .public)"
        )
        let rpcSignpostID = policyCanvasSaveSignposter.makeSignpostID()
        let rpcInterval = policyCanvasSaveSignposter.beginInterval(
          "policy_canvas.save.rpc",
          id: rpcSignpostID,
          "canvas=\(canvasIdentifier, privacy: .public)"
        )
        defer {
          policyCanvasSaveSignposter.endInterval(
            "policy_canvas.save.rpc",
            rpcInterval
          )
        }
        let savedDocument = await saveExportedPolicyCanvasDraft(document)

        await MainActor.run {
          setRuntimePolicyCanvasActionInFlight(false)
          let savedRevision = savedDocument?.revision
          let savedCleanly = viewModel.finishDraftSaveTransaction(
            transaction,
            savedDocument: savedDocument,
            reason: reason
          )
          if savedCleanly, let savedRevision,
            (dashboardSnapshot.document?.revision ?? 0) >= savedRevision
          {
            applyDashboardSnapshot()
          }
        }
      }
    )
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
      let promoted = await runtime?.promotePolicyCanvas(revision: revision) ?? false
      if promoted {
        enforceCanvasAutomationPolicies()
        await forceReloadPolicyPipeline()
      } else {
        statusLine = "Promotion blocked"
      }
    }
  }

  func forceReloadPolicyPipeline() async {
    guard let runtime else {
      return
    }
    await runtime.bootstrapPolicyCanvas()
    await runtime.refreshPolicyCanvas()
    applyDashboardSnapshot()
  }

  func applyDashboardSnapshot() {
    guard !viewModel.isSavingDraft else {
      return
    }
    let snapshot = dashboardSnapshot
    if !viewModel.documentDirty {
      viewModel.applyPersistedDocument(
        document: snapshot.document,
        simulation: snapshot.simulation,
        audit: snapshot.audit,
        activeCanvasId: snapshot.activeCanvasId
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
    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: runtime?.policyCanvasSnapshot.workspace,
      activeDocument: runtime?.policyCanvasSnapshot.document ?? viewModel.exportDocument()
    )
    guard !compilation.policies.isEmpty || automationStore.document.hasCanvasPolicies else {
      statusLine = "Add a canvas source node before enforcing automation policies"
      return
    }
    automationStore.replaceCanvasPolicies(compilation.policies)
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

  @MainActor
  private func setRuntimePolicyCanvasActionInFlight(_ isInFlight: Bool) {
    runtime?.policyCanvasActionInFlight = isInFlight
  }

  @MainActor
  private func saveExportedPolicyCanvasDraft(_ document: TaskBoardPolicyPipelineDocument) async
    -> TaskBoardPolicyPipelineDocument?
  {
    await runtime?.savePolicyCanvasDraft(document: document)
  }
}

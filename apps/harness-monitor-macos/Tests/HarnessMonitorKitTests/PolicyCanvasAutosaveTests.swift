import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas autosave")
@MainActor
struct PolicyCanvasAutosaveTests {
  @Test("schedule autosave coalesces rapid calls into one save")
  func scheduleAutosaveCoalescesIntoOneSave() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 11), simulation: nil, audit: nil)
    // load() clears documentDirty; the trailing-call wakeup re-checks this
    // guard before firing the closure. Simulate a user edit by marking dirty
    // (the production trigger comes from markDocumentDirty() inside
    // mutations).
    viewModel.documentDirty = true
    var saveCalls = 0

    let saveClosure: @MainActor () async -> Void = {
      saveCalls += 1
    }

    // 100 rapid scheduleAutosave calls inside the same 1.5s window should
    // collapse to a single executed save thanks to debounce + task cancellation.
    for _ in 0..<100 {
      viewModel.scheduleAutosave(performSave: saveClosure)
    }

    // Wait long enough for the debounce window (1.5s) + a small slack so
    // the trailing save task definitely fires.
    try? await Task.sleep(for: .milliseconds(2_000))

    #expect(saveCalls == 1)
  }

  @Test("autosave is suppressed when backingDocument is nil")
  func autosaveSuppressedWhenBackingDocumentNil() async {
    let viewModel = PolicyCanvasViewModel.sample()
    var saveCalls = 0

    let saveClosure: @MainActor () async -> Void = {
      saveCalls += 1
    }

    // PolicyCanvasViewModel.sample() initializes backingDocument = nil so
    // the autosave path should bail early. Schedule, wait, observe zero
    // calls.
    viewModel.scheduleAutosave(performSave: saveClosure)
    try? await Task.sleep(for: .milliseconds(2_000))

    #expect(viewModel.backingDocument == nil)
    #expect(saveCalls == 0)
  }

  @Test("rollback armed by restoreState suppresses next autosave")
  func rollbackArmedSuppressesNextAutosave() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 11), simulation: nil, audit: nil)
    var saveCalls = 0
    let saveClosure: @MainActor () async -> Void = {
      saveCalls += 1
    }

    // Simulate a save-reject path: snapshot + a mutation + restoreState.
    let snapshot = viewModel.snapshotState()
    viewModel.createNode(kind: .condition, at: CGPoint(x: 100, y: 100))
    viewModel.restoreState(snapshot, reason: "Save rejected, restored previous canvas")
    // restoreState sets documentDirty = true; if autosave were not
    // suppressed it would fire a save inside the debounce window. The
    // suppression flag should consume the first attempt.
    viewModel.scheduleAutosave(performSave: saveClosure)
    try? await Task.sleep(for: .milliseconds(2_000))

    #expect(saveCalls == 0)
    // After suppression consumes its one shot, subsequent schedule calls
    // should resume normal behavior.
    viewModel.scheduleAutosave(performSave: saveClosure)
    try? await Task.sleep(for: .milliseconds(2_000))
    #expect(saveCalls == 1)
  }

  @Test("autosave is suppressed while foreground save is in flight")
  func autosaveSuppressedWhileForegroundSaveInFlight() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 11), simulation: nil, audit: nil)
    viewModel.documentDirty = true
    var saveCalls = 0
    let saveClosure: @MainActor () async -> Void = {
      saveCalls += 1
    }

    // Simulate a foreground save kicking off: the host view sets
    // isSavingDraft = true before its Task awaits the daemon round-trip.
    viewModel.isSavingDraft = true

    viewModel.scheduleAutosave(performSave: saveClosure)
    try? await Task.sleep(for: .milliseconds(2_000))

    // The autosave path bails at the isSavingDraft guard and the closure
    // never runs.
    #expect(saveCalls == 0)
  }

  @Test("cancelAutosave drops the in-flight debounce task")
  func cancelAutosaveDropsInFlightDebounceTask() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 11), simulation: nil, audit: nil)
    viewModel.documentDirty = true
    var saveCalls = 0
    let saveClosure: @MainActor () async -> Void = {
      saveCalls += 1
    }

    // Schedule autosave then cancel before the debounce window elapses.
    viewModel.scheduleAutosave(performSave: saveClosure)
    try? await Task.sleep(for: .milliseconds(200))
    viewModel.cancelAutosave()
    try? await Task.sleep(for: .milliseconds(2_000))

    #expect(saveCalls == 0)
  }

  @Test("autosave outcome surfaces succeed and fail markers")
  func autosaveOutcomeSurfaceSucceedAndFail() {
    let viewModel = PolicyCanvasViewModel.sample()

    #expect(viewModel.lastAutosaveOutcome == .idle)

    viewModel.markAutosaveSucceeded(at: Date(timeIntervalSince1970: 1_000))
    if case .succeeded(let at) = viewModel.lastAutosaveOutcome {
      #expect(at.timeIntervalSince1970 == 1_000)
    } else {
      Issue.record("Expected succeeded outcome after markAutosaveSucceeded")
    }

    viewModel.markAutosaveFailed(at: Date(timeIntervalSince1970: 2_000))
    if case .failed(let at) = viewModel.lastAutosaveOutcome {
      #expect(at.timeIntervalSince1970 == 2_000)
    } else {
      Issue.record("Expected failed outcome after markAutosaveFailed")
    }
  }

  @Test("mark document dirty fires the autosave trigger on the clean to dirty edge only")
  func markDocumentDirtyFiresOnEdgeOnly() {
    let viewModel = PolicyCanvasViewModel.sample()
    var triggerFiredCount = 0
    viewModel.autosaveTrigger = { @MainActor in
      triggerFiredCount += 1
    }

    // Calling markDocumentDirty repeatedly inside the same dirty window
    // should NOT re-fire the trigger - per-tick drag callbacks would
    // otherwise spawn-and-cancel a Task 60Hz.
    viewModel.markDocumentDirty()
    viewModel.markDocumentDirty()
    viewModel.markDocumentDirty()

    #expect(viewModel.documentDirty)
    #expect(triggerFiredCount == 1)
  }

  @Test("mark document dirty re-fires trigger after dirty was cleared")
  func markDocumentDirtyReFiresAfterClear() {
    let viewModel = PolicyCanvasViewModel.sample()
    var triggerFiredCount = 0
    viewModel.autosaveTrigger = { @MainActor in
      triggerFiredCount += 1
    }

    viewModel.markDocumentDirty()
    #expect(triggerFiredCount == 1)
    // Simulate the save success path clearing dirty. The next dirty edge
    // should fire the trigger again because the flag transitions clean→dirty
    // a second time.
    viewModel.documentDirty = false
    viewModel.markDocumentDirty()

    #expect(triggerFiredCount == 2)
  }

  @Test("createNode flips documentDirty through the trigger funnel")
  func createNodeFlipsDirtyThroughTriggerFunnel() {
    let viewModel = PolicyCanvasViewModel.sample()
    var triggerFiredCount = 0
    viewModel.autosaveTrigger = { @MainActor in
      triggerFiredCount += 1
    }

    viewModel.createNode(kind: .condition, at: CGPoint(x: 100, y: 100))

    #expect(viewModel.documentDirty)
    #expect(triggerFiredCount == 1)
  }

  @Test("debounce window matches the documented 1.5s contract")
  func debounceWindowMatchesContract() {
    // Guard against accidental retiming. If this constant changes the
    // coalescing test's sleep slack needs to move with it.
    #expect(PolicyCanvasViewModel.autosaveDebounceMilliseconds == 1500)
  }

  @Test("three consecutive failures flip outcome to disabled")
  func threeFailuresFlipToDisabled() {
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.markAutosaveFailed(at: Date(timeIntervalSince1970: 1_000))
    if case .failed = viewModel.lastAutosaveOutcome {
      // First failure: stays in .failed.
    } else {
      Issue.record("Expected .failed after first failure")
    }

    viewModel.markAutosaveFailed(at: Date(timeIntervalSince1970: 2_000))
    if case .failed = viewModel.lastAutosaveOutcome {
      // Second failure: stays in .failed.
    } else {
      Issue.record("Expected .failed after second failure")
    }

    viewModel.markAutosaveFailed(at: Date(timeIntervalSince1970: 3_000))
    if case .disabled(let reason) = viewModel.lastAutosaveOutcome {
      #expect(reason == PolicyCanvasViewModel.autosaveDisabledReason)
    } else {
      Issue.record("Expected .disabled after third consecutive failure")
    }
  }

  @Test("autosave is skipped when outcome is disabled")
  func autosaveSkippedWhenDisabled() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 11), simulation: nil, audit: nil)
    viewModel.documentDirty = true
    // Cross the ceiling so the next scheduleAutosave bails.
    viewModel.markAutosaveFailed()
    viewModel.markAutosaveFailed()
    viewModel.markAutosaveFailed()
    if case .disabled = viewModel.lastAutosaveOutcome {
      // expected
    } else {
      Issue.record("Setup expected .disabled outcome before scheduleAutosave")
    }

    var saveCalls = 0
    viewModel.scheduleAutosave {
      saveCalls += 1
    }
    try? await Task.sleep(for: .milliseconds(2_000))

    #expect(saveCalls == 0)
  }

  @Test("manual save success clears decompensation counter")
  func manualSaveSuccessClearsDecompensation() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.markAutosaveFailed()
    viewModel.markAutosaveFailed()
    viewModel.markAutosaveFailed()
    if case .disabled = viewModel.lastAutosaveOutcome {
      // expected
    } else {
      Issue.record("Setup expected .disabled state")
    }
    #expect(viewModel.consecutiveAutosaveFailures == 3)

    viewModel.markManualSaveSucceeded()

    #expect(viewModel.consecutiveAutosaveFailures == 0)
    if case .idle = viewModel.lastAutosaveOutcome {
      // expected - exit .disabled back to .idle until the next autosave fires.
    } else {
      Issue.record("Expected .idle after markManualSaveSucceeded")
    }
  }

  @Test("autosave success clears decompensation counter")
  func autosaveSuccessClearsDecompensation() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.markAutosaveFailed()
    viewModel.markAutosaveFailed()
    #expect(viewModel.consecutiveAutosaveFailures == 2)

    viewModel.markAutosaveSucceeded(at: Date(timeIntervalSince1970: 1_000))

    #expect(viewModel.consecutiveAutosaveFailures == 0)
    if case .succeeded = viewModel.lastAutosaveOutcome {
      // expected
    } else {
      Issue.record("Expected .succeeded after markAutosaveSucceeded")
    }
  }

  @Test("beginForegroundSave sets isSavingDraft synchronously")
  func beginForegroundSaveSetsIsSavingSync() {
    let viewModel = PolicyCanvasViewModel.sample()
    #expect(viewModel.isSavingDraft == false)
    viewModel.beginForegroundSave()
    // No Task await between the call and the assertion: if the flag were
    // set inside an async closure, this read would return false. The
    // synchronous helper closes the race window the host view used to
    // have between cancelAutosave and the Task body's flag flip.
    #expect(viewModel.isSavingDraft == true)
    viewModel.endForegroundSave()
    #expect(viewModel.isSavingDraft == false)
  }

  @Test("recovery buffer captures and recovers edits")
  func recoveryBufferCapturesAndRecovers() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 11), simulation: nil, audit: nil)
    // Snapshot taken before the round-trip starts.
    let snapshot = viewModel.snapshotState()
    let nodesBeforeEdit = viewModel.nodes.count
    // Simulate user typing during the round-trip - add a node post-snapshot.
    viewModel.createNode(kind: .condition, at: CGPoint(x: 220, y: 220))
    let nodesAfterEdit = viewModel.nodes.count
    #expect(nodesAfterEdit == nodesBeforeEdit + 1)

    // Daemon rejects - capture the in-progress state, then restore the
    // pre-save snapshot.
    viewModel.captureRecoveryBuffer()
    viewModel.restoreState(snapshot, reason: "Save rejected, restored previous canvas")
    #expect(viewModel.nodes.count == nodesBeforeEdit)
    #expect(viewModel.hasRecoverableEdits == true)

    // User clicks Recover.
    let recovered = viewModel.recoverRejectedEdits()
    #expect(recovered)
    #expect(viewModel.nodes.count == nodesAfterEdit)
    #expect(viewModel.hasRecoverableEdits == false)
    #expect(viewModel.documentDirty)
  }

  @Test("recovery is no-op without a buffer")
  func recoveryNoopWithoutBuffer() {
    let viewModel = PolicyCanvasViewModel.sample()
    #expect(viewModel.hasRecoverableEdits == false)
    #expect(viewModel.recoverRejectedEdits() == false)
  }

  @Test("scene storage map round trip preserves zoom and selection per pipeline")
  func sceneStorageMapRoundTripPerPipeline() {
    let originalMap: [String: PolicyCanvasPipelineSceneState] = [
      "pipeline-a": PolicyCanvasPipelineSceneState(zoom: 0.85, selectionRaw: "node:a-1"),
      "pipeline-b": PolicyCanvasPipelineSceneState(zoom: 1.2, selectionRaw: "edge:b-2"),
    ]
    let encoded = PolicyCanvasView.encodePipelineStateMap(originalMap)
    let decoded = PolicyCanvasView.decodePipelineStateMap(encoded)

    #expect(decoded == originalMap)
  }

  @Test("scene storage decodes empty input to empty map")
  func sceneStorageDecodesEmptyMap() {
    let map = PolicyCanvasView.decodePipelineStateMap("")
    #expect(map.isEmpty)
  }

  @Test("scene storage decodes corrupt input to empty map without crashing")
  func sceneStorageDecodesCorruptMap() {
    let map = PolicyCanvasView.decodePipelineStateMap("not-valid-json{")
    #expect(map.isEmpty)
  }
}

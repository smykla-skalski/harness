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

  @Test("mark document dirty fires the autosave trigger")
  func markDocumentDirtyFiresAutosaveTrigger() {
    let viewModel = PolicyCanvasViewModel.sample()
    var triggerFiredCount = 0
    viewModel.autosaveTrigger = { @MainActor in
      triggerFiredCount += 1
    }

    viewModel.markDocumentDirty()
    viewModel.markDocumentDirty()

    #expect(viewModel.documentDirty)
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
}

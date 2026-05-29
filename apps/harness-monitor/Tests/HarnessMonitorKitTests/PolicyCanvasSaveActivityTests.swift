import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// The bottom-right save-status pill reads `PolicyCanvasViewModel.saveActivity`.
/// These pin both the pure presentation mapping (case -> spinner/label/symbol)
/// and the view-model transitions that drive it through the save flow, so the
/// pill ships with its producer wired end to end.
@Suite("Policy canvas save activity")
@MainActor
struct PolicyCanvasSaveActivityTests {
  // MARK: presentation mapping

  @Test("idle hides the pill")
  func idleHidesPill() {
    #expect(PolicyCanvasSaveActivity.idle.presentation.isVisible == false)
  }

  @Test("pending shows a spinner labelled Saving")
  func pendingShowsSpinner() {
    let presentation = PolicyCanvasSaveActivity.pending.presentation
    #expect(presentation.isVisible)
    #expect(presentation.showsSpinner)
    #expect(presentation.label == "Saving…")
    #expect(presentation.role == .progress)
  }

  @Test("saving shows a spinner labelled Saving")
  func savingShowsSpinner() {
    let presentation = PolicyCanvasSaveActivity.saving.presentation
    #expect(presentation.isVisible)
    #expect(presentation.showsSpinner)
    #expect(presentation.label == "Saving…")
    #expect(presentation.role == .progress)
  }

  @Test("saved shows a check without a spinner")
  func savedShowsCheck() {
    let activity = PolicyCanvasSaveActivity.saved(at: Date(timeIntervalSince1970: 1_000))
    let presentation = activity.presentation
    #expect(presentation.isVisible)
    #expect(presentation.showsSpinner == false)
    #expect(presentation.label == "Saved")
    #expect(presentation.symbolName == "checkmark.circle.fill")
    #expect(presentation.role == .success)
  }

  @Test("failed shows an error marker without a spinner")
  func failedShowsError() {
    let presentation = PolicyCanvasSaveActivity.failed.presentation
    #expect(presentation.isVisible)
    #expect(presentation.showsSpinner == false)
    #expect(presentation.symbolName == "exclamationmark.triangle.fill")
    #expect(presentation.role == .failure)
  }

  // MARK: view-model transitions

  @Test("beginForegroundSave moves activity to saving")
  func beginForegroundSaveEntersSaving() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.beginForegroundSave()
    #expect(viewModel.saveActivity == .saving)
    viewModel.cancelAutosave()
  }

  @Test("scheduleAutosave arms the pending indicator once guards pass")
  func scheduleAutosaveEntersPending() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 7), simulation: nil, audit: nil)
    viewModel.documentDirty = true
    viewModel.scheduleAutosave {}
    #expect(viewModel.saveActivity == .pending)
    viewModel.cancelAutosave()
  }

  @Test("scheduleAutosave leaves activity idle when guards reject")
  func scheduleAutosaveSkipsPendingWhenSuppressed() {
    let viewModel = PolicyCanvasViewModel.sample()
    // backingDocument is nil on a fresh sample, so the scheduler bails before
    // arming. The pill must not light up for a save that never happens.
    viewModel.scheduleAutosave {}
    #expect(viewModel.saveActivity == .idle)
  }

  @Test("a clean successful save flashes the saved check")
  func resolveSuccessfulSaveFlashesSaved() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 7), simulation: nil, audit: nil)
    viewModel.createNode(kind: .condition, at: CGPoint(x: 120, y: 120))
    let saved = viewModel.exportDocument()

    _ = viewModel.resolveSuccessfulSave(savedDocument: saved)

    if case .saved = viewModel.saveActivity {
      // expected
    } else {
      Issue.record("Expected .saved after a clean successful save")
    }
  }

  @Test("an edited-during-save round-trip does not flash saved")
  func resolveSuccessfulSaveKeepsSpinnerOnConcurrentEdit() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 7), simulation: nil, audit: nil)
    viewModel.createNode(kind: .condition, at: CGPoint(x: 120, y: 120))
    let saved = viewModel.exportDocument()
    viewModel.saveActivity = .saving
    // User edits while the round-trip is in flight: the live graph diverges
    // from what was sent, so a follow-up save is queued and the pill must not
    // claim "Saved".
    viewModel.createNode(kind: .condition, at: CGPoint(x: 300, y: 300))

    _ = viewModel.resolveSuccessfulSave(savedDocument: saved)

    if case .saved = viewModel.saveActivity {
      Issue.record("Concurrent-edit save must not flash .saved")
    }
  }

  @Test("markSaveActivityFailed surfaces the failed marker")
  func markSaveActivityFailedSetsFailed() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.markSaveActivityFailed()
    #expect(viewModel.saveActivity == .failed)
  }

  @Test("flashSaveActivity auto-clears back to idle after the window")
  func flashSaveActivityAutoClears() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.flashSaveActivity(
      .saved(at: Date(timeIntervalSince1970: 1_000)),
      clearAfter: .milliseconds(150)
    )
    if case .saved = viewModel.saveActivity {
      // expected immediately after arming
    } else {
      Issue.record("Expected .saved immediately after flashSaveActivity")
    }
    try? await Task.sleep(for: .milliseconds(450))
    #expect(viewModel.saveActivity == .idle)
  }

  @Test("a new save cancels a stale saved auto-clear")
  func newSaveCancelsAutoClear() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.flashSaveActivity(
      .saved(at: Date(timeIntervalSince1970: 1_000)),
      clearAfter: .milliseconds(150)
    )
    // A fresh save starts before the clear fires.
    viewModel.beginForegroundSave()
    #expect(viewModel.saveActivity == .saving)
    try? await Task.sleep(for: .milliseconds(450))
    // The stale clear must not stomp the in-flight save back to idle.
    #expect(viewModel.saveActivity == .saving)
    viewModel.cancelAutosave()
  }
}

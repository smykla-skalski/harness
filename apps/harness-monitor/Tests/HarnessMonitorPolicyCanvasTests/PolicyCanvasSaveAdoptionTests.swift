import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// A successful save adopts the saved revision as the new clean backing without
/// a reload (no viewport recenter, no undo wipe), records the revision as our
/// own so the daemon's echo of the save is not mistaken for a remote change,
/// and keeps the canvas dirty only when the user edited during the round-trip.
@Suite("Policy canvas save adoption")
@MainActor
struct PolicyCanvasSaveAdoptionTests {
  @Test("markSavedDocument adopts a clean backing and records the self-saved revision")
  func markSavedDocumentAdoptsCleanBacking() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 5), simulation: nil, audit: nil)
    viewModel.documentDirty = true
    let saved = viewModel.exportDocument()

    viewModel.markSavedDocument(saved)

    #expect(viewModel.documentDirty == false)
    #expect(viewModel.backingDocument == saved)
    #expect(viewModel.loadedDocumentRevision == 5)
    #expect(viewModel.lastSelfSavedRevision == 5)
    #expect(viewModel.pendingDocumentUpdate == nil)
  }

  @Test("resolveSuccessfulSave adopts cleanly when no edit landed during the round-trip")
  func resolveSuccessfulSaveCleanWhenNoConcurrentEdit() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 5), simulation: nil, audit: nil)
    viewModel.createNode(kind: .condition, at: CGPoint(x: 120, y: 120))
    let saved = viewModel.exportDocument()
    let saveGeneration = viewModel.documentGeneration

    let needsFollowUp = viewModel.resolveSuccessfulSave(
      saveGeneration: saveGeneration,
      savedDocument: saved
    )

    #expect(needsFollowUp == false)
    #expect(viewModel.documentDirty == false)
    #expect(viewModel.lastSelfSavedRevision == 5)
    #expect(viewModel.backingDocument == saved)
  }

  @Test("resolveSuccessfulSave keeps dirty and asks for a follow-up when edited mid-save")
  func resolveSuccessfulSaveKeepsDirtyOnConcurrentEdit() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 5), simulation: nil, audit: nil)
    viewModel.createNode(kind: .condition, at: CGPoint(x: 120, y: 120))
    let saved = viewModel.exportDocument()
    let saveGeneration = viewModel.documentGeneration
    // Simulate the user editing during the daemon round-trip: the live graph
    // now advances past the generation that was sent.
    viewModel.createNode(kind: .condition, at: CGPoint(x: 300, y: 300))

    let needsFollowUp = viewModel.resolveSuccessfulSave(
      saveGeneration: saveGeneration,
      savedDocument: saved
    )

    #expect(needsFollowUp == true)
    #expect(viewModel.documentDirty == true)
    #expect(viewModel.lastSelfSavedRevision == 5)
  }

  @Test("a clean save adopts the daemon's bumped revision, not the one we sent")
  func cleanSaveAdoptsDaemonBumpedRevision() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 5), simulation: nil, audit: nil)
    let sent = viewModel.exportDocument()
    let saveGeneration = viewModel.documentGeneration
    // The daemon persists the same content at a bumped revision on every save.
    var daemonSaved = sent
    daemonSaved.revision = 6

    let needsFollowUp = viewModel.resolveSuccessfulSave(
      saveGeneration: saveGeneration,
      savedDocument: daemonSaved
    )

    #expect(needsFollowUp == false)
    #expect(viewModel.backingDocument?.revision == 6)
    #expect(viewModel.loadedDocumentRevision == 6)
    #expect(viewModel.lastSelfSavedRevision == 6)
  }

  @Test("a concurrent edit records the daemon's bumped revision as our own")
  func concurrentEditRecordsDaemonBumpedRevision() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 5), simulation: nil, audit: nil)
    let sent = viewModel.exportDocument()
    let saveGeneration = viewModel.documentGeneration
    var daemonSaved = sent
    daemonSaved.revision = 6
    // User edits during the round-trip.
    viewModel.createNode(kind: .condition, at: CGPoint(x: 300, y: 300))

    let needsFollowUp = viewModel.resolveSuccessfulSave(
      saveGeneration: saveGeneration,
      savedDocument: daemonSaved
    )

    #expect(needsFollowUp == true)
    #expect(viewModel.documentDirty == true)
    #expect(viewModel.lastSelfSavedRevision == 6)
  }

  @Test("a concurrent edit advances the backing revision so the follow-up if_revision is current")
  func concurrentEditAdvancesBackingRevision() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 5), simulation: nil, audit: nil)
    let sent = viewModel.exportDocument()
    let saveGeneration = viewModel.documentGeneration
    var daemonSaved = sent
    daemonSaved.revision = 6
    // User keeps editing during the round-trip (a continuous node drag bumps the
    // generation every tick), so the save lands diverged.
    viewModel.createNode(kind: .condition, at: CGPoint(x: 300, y: 300))

    _ = viewModel.resolveSuccessfulSave(saveGeneration: saveGeneration, savedDocument: daemonSaved)

    // The re-armed follow-up save exports at backingDocument.revision for its
    // if_revision. It must be the daemon's bumped revision (6), not the stale
    // pre-save revision (5) - otherwise the daemon rejects the queued follow-up
    // as a concurrent edit (WORKFLOW_CONCURRENT: expected 5, found 6).
    #expect(viewModel.backingDocument?.revision == 6)
    #expect(viewModel.exportDocument().revision == 6)
  }

  @Test("the daemon's bumped echo after a concurrent-edit save is not a remote change")
  func bumpedEchoAfterConcurrentEditDoesNotBanner() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 5), simulation: nil, audit: nil)
    let sent = viewModel.exportDocument()
    let saveGeneration = viewModel.documentGeneration
    var daemonSaved = sent
    daemonSaved.revision = 6
    viewModel.createNode(kind: .condition, at: CGPoint(x: 300, y: 300))
    _ = viewModel.resolveSuccessfulSave(saveGeneration: saveGeneration, savedDocument: daemonSaved)
    #expect(viewModel.documentDirty == true)

    // The store now republishes the daemon's saved document at revision 6.
    // Because we recorded 6 as self-saved, this echo must not raise the banner
    // and must keep the user's in-flight edit.
    viewModel.load(document: daemonSaved, simulation: nil, audit: nil)

    #expect(viewModel.hasPendingDocumentUpdate == false)
    #expect(viewModel.documentDirty == true)
  }

  @Test("draft save transaction clean success exits saving and adopts the saved backing")
  func draftSaveTransactionCleanSuccessAdoptsBacking() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 5), simulation: nil, audit: nil)
    viewModel.createNode(kind: .condition, at: CGPoint(x: 120, y: 120))
    let transaction = viewModel.beginDraftSaveTransaction()
    var saved = transaction.exportDocument()
    saved.revision = 6

    let savedCleanly = viewModel.finishDraftSaveTransaction(
      transaction,
      savedDocument: saved,
      reason: .manualSave
    )

    #expect(savedCleanly)
    #expect(viewModel.isSavingDraft == false)
    #expect(viewModel.documentDirty == false)
    #expect(viewModel.backingDocument?.revision == 6)
  }

  @Test("draft save transaction failure rolls back through the same recovery path")
  func draftSaveTransactionFailureRollsBack() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 5), simulation: nil, audit: nil)
    viewModel.createNode(kind: .condition, at: CGPoint(x: 120, y: 120))
    let transaction = viewModel.beginDraftSaveTransaction()
    let sentNodeIDs = Set(transaction.exportDocument().nodes.map(\.id))
    viewModel.createNode(kind: .condition, at: CGPoint(x: 300, y: 300))

    let savedCleanly = viewModel.finishDraftSaveTransaction(
      transaction,
      savedDocument: nil,
      reason: .manualSave
    )

    #expect(savedCleanly == false)
    #expect(viewModel.isSavingDraft == false)
    #expect(viewModel.documentDirty)
    #expect(viewModel.saveActivity == .failed)
    #expect(Set(viewModel.exportDocument().nodes.map(\.id)) == sentNodeIDs)
    #expect(viewModel.hasRecoverableEdits)
  }

  @Test("draft save transaction edited during save stays dirty and re-arms autosave")
  func draftSaveTransactionEditedDuringSaveReArmsAutosave() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 5), simulation: nil, audit: nil)
    viewModel.createNode(kind: .condition, at: CGPoint(x: 120, y: 120))
    var triggerFired = 0
    viewModel.autosaveTrigger = { @MainActor in triggerFired += 1 }
    let transaction = viewModel.beginDraftSaveTransaction()
    var saved = transaction.exportDocument()
    saved.revision = 6
    viewModel.createNode(kind: .condition, at: CGPoint(x: 300, y: 300))

    let savedCleanly = viewModel.finishDraftSaveTransaction(
      transaction,
      savedDocument: saved,
      reason: .manualSave
    )

    #expect(savedCleanly == false)
    #expect(viewModel.isSavingDraft == false)
    #expect(viewModel.documentDirty)
    #expect(viewModel.lastSelfSavedRevision == 6)
    #expect(triggerFired == 1)
  }

  @Test("endForegroundSave re-arms autosave when edits remain after the save")
  func endForegroundSaveReArmsWhenDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    var triggerFired = 0
    viewModel.autosaveTrigger = { @MainActor in triggerFired += 1 }
    viewModel.documentDirty = true

    // isSavingDraft is true through the save, which would swallow a re-arm
    // scheduled inside the task; endForegroundSave clears it then re-arms.
    viewModel.beginForegroundSave()
    viewModel.endForegroundSave()

    #expect(viewModel.isSavingDraft == false)
    #expect(triggerFired == 1)
  }

  @Test("endForegroundSave does not re-arm when the canvas is clean")
  func endForegroundSaveSilentWhenClean() {
    let viewModel = PolicyCanvasViewModel.sample()
    var triggerFired = 0
    viewModel.autosaveTrigger = { @MainActor in triggerFired += 1 }

    viewModel.beginForegroundSave()
    viewModel.endForegroundSave()

    #expect(triggerFired == 0)
  }
}

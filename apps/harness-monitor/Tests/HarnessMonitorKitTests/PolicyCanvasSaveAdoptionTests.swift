import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

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

    let needsFollowUp = viewModel.resolveSuccessfulSave(savedDocument: saved)

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
    // Simulate the user editing during the daemon round-trip: the live graph
    // now diverges from what was sent.
    viewModel.createNode(kind: .condition, at: CGPoint(x: 300, y: 300))

    let needsFollowUp = viewModel.resolveSuccessfulSave(savedDocument: saved)

    #expect(needsFollowUp == true)
    #expect(viewModel.documentDirty == true)
    #expect(viewModel.lastSelfSavedRevision == 5)
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

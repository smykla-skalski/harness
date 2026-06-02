import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

/// The "Remote changes available" affordance must fire only when the daemon
/// holds a revision strictly newer than the one we are editing from — never on
/// our own pending edits, our own save echo, or a same-revision re-serialize.
/// Before the revision gate, `load()` staged a pending update whenever an
/// incoming document was not byte-identical to `backingDocument` while dirty,
/// so any daemon republish during editing tripped the banner and dropped the
/// edit.
@Suite("Policy canvas remote-change revision gate")
@MainActor
struct PolicyCanvasRemoteChangeRevisionGateTests {
  @Test("same-revision republish while dirty does not stage a pending update")
  func sameRevisionRepublishWhileDirtyDoesNotStagePending() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 11), simulation: nil, audit: nil)
    let backingNodeCount = viewModel.nodes.count

    // Simulate a local edit, then a daemon republish of the SAME revision with
    // different bytes (e.g. a re-serialized layout). This is not a remote
    // change — it must keep local edits and never raise the banner.
    viewModel.documentDirty = true
    viewModel.load(document: richPolicyDocument(revision: 11), simulation: nil, audit: nil)

    #expect(viewModel.hasPendingDocumentUpdate == false)
    #expect(viewModel.nodes.count == backingNodeCount)
    #expect(viewModel.documentDirty == true)
  }

  @Test("own save echo while dirty does not stage a pending update")
  func ownSaveEchoWhileDirtyDoesNotStagePending() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 11), simulation: nil, audit: nil)

    // The save coordinator records the revision it just persisted. The daemon
    // then echoes that revision back. Even though it is numerically newer than
    // the loaded revision, it is our own save — not a remote change.
    viewModel.documentDirty = true
    viewModel.lastSelfSavedRevision = 12
    viewModel.load(document: richPolicyDocument(revision: 12), simulation: nil, audit: nil)

    #expect(viewModel.hasPendingDocumentUpdate == false)
    #expect(viewModel.documentDirty == true)
  }

  @Test("strictly newer remote revision while dirty stages a pending update")
  func newerRemoteRevisionWhileDirtyStagesPending() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 11), simulation: nil, audit: nil)
    let backingNodeCount = viewModel.nodes.count

    // A genuinely newer revision from another writer arrives while we have
    // unsaved edits: stage it as a pending update so the chrome can offer a
    // reload, and keep local edits untouched until the user chooses.
    viewModel.documentDirty = true
    viewModel.load(document: richPolicyDocument(revision: 12), simulation: nil, audit: nil)

    #expect(viewModel.hasPendingDocumentUpdate == true)
    #expect(viewModel.nodes.count == backingNodeCount)
    #expect(viewModel.documentDirty == true)
  }

  @Test("newer remote revision while clean applies without a pending update")
  func newerRemoteRevisionWhileCleanApplies() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 11), simulation: nil, audit: nil)

    // No local edits: a newer revision loads straight through, no banner.
    viewModel.load(document: richPolicyDocument(revision: 12), simulation: nil, audit: nil)

    #expect(viewModel.hasPendingDocumentUpdate == false)
    #expect(viewModel.backingDocument?.revision == 12)
    #expect(viewModel.documentDirty == false)
  }
}

#if DEBUG
import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas hot reload")
@MainActor
struct PolicyCanvasHotReloadTests {
  /// Regression: after the lab hot-reloads (InjectionIII / InjectionNext), the
  /// injection handler recomputes the canvas. That recompute must not leave the
  /// document dirty, because `shouldApplyExternalDocument`'s dirty guard then
  /// refuses every later policy switch and the canvas freezes on the old graph.
  @Test("switching policies still updates the canvas after a hot-reload recompute")
  func switchingPoliciesUpdatesAfterHotReloadRecompute() {
    let viewModel = PolicyCanvasViewModel.liveStartupState(
      document: overlappingDefaultPolicyDocument(revision: 1),
      simulation: nil,
      audit: nil,
      algorithmSelection: .harnessCurrent
    )

    // Mimic the lab's injection handler recompute on the displayed document.
    viewModel.applyHotReloadedAlgorithms(
      document: overlappingDefaultPolicyDocument(revision: 1),
      simulation: nil,
      audit: nil
    )

    // A subsequent policy switch must load the new document into the canvas.
    viewModel.loadIfChanged(
      document: richPolicyDocument(revision: 2),
      simulation: nil,
      audit: nil
    )

    #expect(viewModel.nodes.contains { $0.id == "node-evidence" })
    #expect(!viewModel.nodes.contains { $0.id == "action:router" })
  }

  /// Documents the root cause: a forced reflow dirties the document, which makes
  /// `shouldApplyExternalDocument` refuse a different policy. The hot-reload
  /// handler must therefore recompute via a forced document reload, not reflow.
  @Test("a forced reflow marks the document dirty and blocks external loads")
  func reflowMarksDirtyAndBlocksExternalLoad() {
    let viewModel = PolicyCanvasViewModel.liveStartupState(
      document: overlappingDefaultPolicyDocument(revision: 1),
      simulation: nil,
      audit: nil,
      algorithmSelection: .harnessCurrent
    )

    viewModel.reflowLayout(preserveManualAnchors: false, force: true)

    #expect(viewModel.documentDirty)
    #expect(!viewModel.shouldApplyExternalDocument(richPolicyDocument(revision: 2)))
  }

  /// The injection chime must resolve to a real macOS system sound. A typo in
  /// the sound name would silently no-op and drop the audible cue that tells the
  /// user a hot reload landed and the lab window is worth a glance.
  @Test("the hot-reload chime resolves a real system sound")
  func reloadChimeResolvesSystemSound() {
    #expect(PolicyCanvasHotReload.reloadChimeSound() != nil)
  }
}
#endif

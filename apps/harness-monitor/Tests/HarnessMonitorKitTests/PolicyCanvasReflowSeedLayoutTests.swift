import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas reflow keeps an already-tidy seeded layout")
@MainActor
struct PolicyCanvasReflowSeedLayoutTests {
  @Test("Reformat leaves the daemon's tidy seeded layout untouched")
  func reflowKeepsTidySeededLayoutUntouched() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.load(document: seededDefaultPolicyDocument(revision: 920), simulation: nil, audit: nil)

    // The seeded coordinates are tidy (no overlaps, every node inside its group
    // frame), so loading them keeps the saved arrangement as trusted/manual
    // coordinates - no auto-arrange runs. This is the live first-load state the
    // user calls "almost good".
    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .manual })

    let positionsBeforeReflow = Dictionary(
      uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) }
    )

    viewModel.reflowLayout()

    // Pressing Reformat without touching anything must not re-run the layered
    // engine over an already-tidy layout. The engine's depth-based output sprawls
    // the terminal column across the canvas (the scramble the user reported), so
    // a tidy layout has to be preserved exactly.
    for node in viewModel.nodes {
      #expect(
        node.position == positionsBeforeReflow[node.id],
        """
        \(node.id) moved on Reformat of an already-tidy seeded layout: \
        \(String(describing: positionsBeforeReflow[node.id])) -> \(node.position)
        """
      )
    }
    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .manual })
    #expect(!undoManager.canUndo)
  }
}

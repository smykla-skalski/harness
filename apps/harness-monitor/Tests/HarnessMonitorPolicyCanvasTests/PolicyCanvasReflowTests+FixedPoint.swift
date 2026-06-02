import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

extension PolicyCanvasReflowTests {
  @Test("reflow on an unchanged saved (manual) graph reproduces the same layout")
  func reflowOnUnchangedManualGraphIsAFixedPoint() {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    // The live Dashboard>Policies path for a saved policy: a non-overlapping
    // layout loads as trusted coordinates, so every node is .manual and no
    // auto-arrange runs. Reformat then drops the anchors and re-lays out - it
    // must reproduce the on-screen arrangement, not reseed the terminal column
    // to graph order, which is the scramble the user sees.
    for index in viewModel.nodes.indices {
      viewModel.nodes[index].layoutSource = .manual
    }
    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .manual })

    let positionsBeforeReflow = Dictionary(
      uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) }
    )
    viewModel.reflowLayout()

    for node in viewModel.nodes {
      #expect(
        node.position == positionsBeforeReflow[node.id],
        """
        \(node.id) moved on a no-op manual reflow: \
        \(String(describing: positionsBeforeReflow[node.id])) -> \(node.position)
        """
      )
    }
  }

  @Test("reflow on an unchanged loaded graph reproduces the same layout")
  func reflowOnUnchangedGraphIsAFixedPoint() {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    // Loading an overlapping fixture auto-arranges every node, so there are no
    // manual anchors. This is exactly the path Reformat takes when the user
    // presses it without dragging anything, and it must not reshuffle a layout
    // that is already clean.
    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .auto })

    let positionsBeforeReflow = Dictionary(
      uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) }
    )
    viewModel.reflowLayout()

    for node in viewModel.nodes {
      #expect(
        node.position == positionsBeforeReflow[node.id],
        """
        \(node.id) moved on a no-op reflow: \
        \(String(describing: positionsBeforeReflow[node.id])) -> \(node.position)
        """
      )
    }
  }
}

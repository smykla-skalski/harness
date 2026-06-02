import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas reflow keeps an already-tidy seeded layout")
@MainActor
struct PolicyCanvasReflowSeedLayoutTests {
  @Test("Reformat leaves the daemon's tidy seeded layout untouched")
  func reflowKeepsTidySeededLayoutUntouched() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.load(
      document: seededDefaultPolicyDocument(revision: 920),
      simulation: nil,
      audit: nil
    )

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

  @Test("Reformat on a messy layout keeps the flow wider than it is tall")
  func reflowKeepsFlowWiderThanTall() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: seededDefaultPolicyDocument(revision: 942),
      simulation: nil,
      audit: nil
    )
    // Collapse every node onto one point so the engine has to re-place all of
    // them - the worst-case messy input a Reformat has to recover from.
    for index in viewModel.nodes.indices {
      viewModel.nodes[index].position = CGPoint(x: 1_000, y: 1_000)
    }
    #expect(policyCanvasNeedsDefaultArrangement(nodes: viewModel.nodes, groups: viewModel.groups))

    viewModel.reflowLayout()

    let bounds = policyCanvasBounds(nodes: viewModel.nodes, groups: viewModel.groups)
    // The seed flows left-to-right across three group columns, so the arranged
    // result must read as a row, not a tall diagonal cascade.
    #expect(
      bounds.width >= bounds.height,
      "arranged flow is taller (\(bounds.height)) than wide (\(bounds.width))"
    )
  }

  @Test("Reformat on a messy layout converges - a second Reformat is a no-op")
  func reflowConvergesToTidyLayout() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: seededDefaultPolicyDocument(revision: 943),
      simulation: nil,
      audit: nil
    )
    if let index = viewModel.nodes.firstIndex(where: { $0.id == "supervisor:auto-merge" }) {
      viewModel.nodes[index].position = CGPoint(x: 80, y: 124)
    }
    #expect(policyCanvasNeedsDefaultArrangement(nodes: viewModel.nodes, groups: viewModel.groups))

    viewModel.reflowLayout()

    // The engine's own output must satisfy the tidiness gate it uses to decide
    // whether to run, otherwise pressing Reformat again would re-arrange a
    // just-arranged layout.
    #expect(!policyCanvasNeedsDefaultArrangement(nodes: viewModel.nodes, groups: viewModel.groups))
    let positionsAfterFirst = Dictionary(
      uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) }
    )
    viewModel.reflowLayout()
    for node in viewModel.nodes {
      #expect(
        node.position == positionsAfterFirst[node.id],
        "\(node.id) moved on a second Reformat of an arranged layout"
      )
    }
  }
}

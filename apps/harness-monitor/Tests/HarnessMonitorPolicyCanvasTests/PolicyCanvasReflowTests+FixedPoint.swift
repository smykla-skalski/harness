import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasReflowTests {
  @Test("persisted reload preserves displayed routes for a saved formatted graph")
  func persistedReloadPreservesDisplayedRoutesForSavedFormattedGraph() async {
    let source = PolicyCanvasViewModel.sample()
    source.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )
    let expectedOutput = await routeOutput(for: source)
    let savedDocument = source.exportDocument()

    let reloaded = PolicyCanvasViewModel.sample()
    reloaded.applyPersistedDocument(
      document: savedDocument,
      simulation: nil,
      audit: nil,
      activeCanvasId: "default"
    )
    let reloadedOutput = await routeOutput(for: reloaded)

    #expect(reloaded.routingHints != nil)
    #expect(reloadedOutput.signature == expectedOutput.signature)
    #expect(reloadedOutput.routes == expectedOutput.routes)
  }

  @Test("no-op Reformat restores missing routing hints without dirtying the document")
  func noOpReformatRestoresMissingRoutingHintsWithoutDirtyingTheDocument() {
    let source = PolicyCanvasViewModel.sample()
    source.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )
    let savedDocument = source.exportDocument()

    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.applyPersistedDocument(
      document: savedDocument,
      simulation: nil,
      audit: nil,
      activeCanvasId: "default"
    )
    let expectedRoutingHints = policyCanvasRoutingHintsForCurrentLayout(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges
    )
    let positionsBeforeReflow = Dictionary(
      uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) }
    )
    viewModel.routingHints = nil
    viewModel.documentDirty = false
    let previousRequestGeneration = viewModel.routeComputationRequestGeneration

    viewModel.reflowLayout()

    #expect(viewModel.routingHints == expectedRoutingHints)
    #expect(viewModel.documentDirty == false)
    #expect(viewModel.routeComputationRequestGeneration == previousRequestGeneration &+ 1)
    for node in viewModel.nodes {
      #expect(node.position == positionsBeforeReflow[node.id])
    }
  }

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

  private func routeOutput(
    for viewModel: PolicyCanvasViewModel
  ) async -> PolicyCanvasRouteWorkerOutput {
    await PolicyCanvasRouteWorker(router: PolicyCanvasVisibilityRouter()).compute(
      input: PolicyCanvasRouteWorkerInput(
        graphGeneration: viewModel.routeComputationGeneration,
        nodes: viewModel.nodes,
        groups: viewModel.groups,
        edges: viewModel.edges,
        fontScale: 1,
        routingHints: viewModel.routingHints
      )
    )
  }
}

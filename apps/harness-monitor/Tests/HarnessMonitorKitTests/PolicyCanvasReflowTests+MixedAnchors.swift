import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension PolicyCanvasReflowTests {
  @Test("reflow runs for a tidy mixed manual and auto layout")
  func reflowRunsForTidyMixedManualAndAutoLayout() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: overlappingReflowDocument(revision: 944), simulation: nil, audit: nil)

    guard
      let sourceIndex = viewModel.nodes.firstIndex(where: { $0.id == "source-node" }),
      let targetBeforeReflow = viewModel.node("target-node")
    else {
      Issue.record("Expected source and target nodes for mixed reflow test")
      return
    }

    let anchoredSource = viewModel.snapped(
      CGPoint(
        x: targetBeforeReflow.position.x + 720,
        y: targetBeforeReflow.position.y + 160
      )
    )
    viewModel.nodes[sourceIndex].position = anchoredSource
    viewModel.nodes[sourceIndex].layoutSource = .manual
    viewModel.reconcileGroupFrames()

    #expect(viewModel.node("source-node")?.layoutSource == .manual)
    #expect(viewModel.node("target-node")?.layoutSource == .auto)
    #expect(!policyCanvasNeedsDefaultArrangement(nodes: viewModel.nodes, groups: viewModel.groups))

    var predictedNodes = viewModel.nodes
    var predictedGroups = viewModel.groups
    guard
      let predictedResult = policyCanvasAutomaticLayoutResult(
        nodes: predictedNodes,
        groups: predictedGroups,
        edges: viewModel.edges,
        mode: .explicitReflow(preserveManualAnchors: true)
      )
    else {
      Issue.record("Expected a predicted layout result for mixed reflow test")
      return
    }
    _ = applyPolicyCanvasLayoutResult(
      predictedResult,
      nodes: &predictedNodes,
      groups: &predictedGroups,
      centerInMinimumCanvas: false
    )
    guard let predictedTarget = predictedNodes.first(where: { $0.id == "target-node" }) else {
      Issue.record("Expected predicted target node for mixed reflow test")
      return
    }

    #expect(predictedTarget.position != targetBeforeReflow.position)

    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.reflowLayout()

    #expect(viewModel.node("source-node")?.position == anchoredSource)
    #expect(viewModel.node("target-node")?.position == predictedTarget.position)
    #expect(undoManager.canUndo)
  }
}

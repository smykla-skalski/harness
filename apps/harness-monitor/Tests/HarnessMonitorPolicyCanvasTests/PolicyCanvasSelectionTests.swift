import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas selection")
@MainActor
struct PolicyCanvasSelectionTests {
  @Test("selecting a node exposes that node and nils the other accessors")
  func selectingNodeExposesOnlyNode() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "risk-score"

    viewModel.select(.node(nodeID))

    #expect(viewModel.selection == .node(nodeID))
    #expect(viewModel.selectedNode?.id == nodeID)
    #expect(viewModel.selectedGroup == nil)
    #expect(viewModel.selectedEdge == nil)
    #expect(viewModel.selectedTitle == viewModel.node(nodeID)?.title)
  }

  @Test("transition node -> group flips computed accessors atomically")
  func transitionNodeToGroupFlipsAccessors() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("risk-score"))
    #expect(viewModel.selectedNode != nil)

    let groupID = "group-evaluation"
    viewModel.select(.group(groupID))

    #expect(viewModel.selection == .group(groupID))
    #expect(viewModel.selectedNode == nil)
    #expect(viewModel.selectedGroup?.id == groupID)
    #expect(viewModel.selectedEdge == nil)
    #expect(viewModel.selectedTitle == viewModel.group(groupID)?.title)
  }

  @Test("transition group -> edge flips computed accessors atomically")
  func transitionGroupToEdgeFlipsAccessors() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.group("group-evaluation"))

    let edgeID = "edge-intake-risk"
    viewModel.select(.edge(edgeID))

    #expect(viewModel.selection == .edge(edgeID))
    #expect(viewModel.selectedNode == nil)
    #expect(viewModel.selectedGroup == nil)
    #expect(viewModel.selectedEdge?.id == edgeID)
    #expect(viewModel.selectedTitle == viewModel.selectedEdge?.label)
  }

  @Test("transition edge -> nil clears every selection accessor")
  func transitionEdgeToNilClearsAccessors() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.edge("edge-intake-risk"))
    #expect(viewModel.selectedEdge != nil)

    viewModel.select(nil)

    #expect(viewModel.selection == nil)
    #expect(viewModel.selectedNode == nil)
    #expect(viewModel.selectedGroup == nil)
    #expect(viewModel.selectedEdge == nil)
    #expect(viewModel.selectedTitle == "Canvas")
  }

  @Test("at most one selection accessor is non-nil at any time")
  func singleSourceOfTruthAcrossTransitions() {
    let viewModel = PolicyCanvasViewModel.sample()

    let sequence: [PolicyCanvasSelection?] = [
      .node("policy-source"),
      .group("group-intake"),
      .edge("edge-intake-risk"),
      .node("review-gate"),
      nil,
      .edge("edge-risk-review"),
      .group("group-release"),
      nil,
    ]

    for selection in sequence {
      viewModel.select(selection)
      let activeCount =
        (viewModel.selectedNode == nil ? 0 : 1)
        + (viewModel.selectedGroup == nil ? 0 : 1)
        + (viewModel.selectedEdge == nil ? 0 : 1)
      switch selection {
      case .none:
        #expect(activeCount == 0)
      case .some:
        #expect(activeCount == 1)
      }
      #expect(viewModel.selection == selection)
    }
  }

  @Test("selecting an unknown node id yields nil node despite selection state")
  func selectingMissingNodeReturnsNilAccessor() {
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.select(.node("does-not-exist"))

    #expect(viewModel.selection == .node("does-not-exist"))
    #expect(viewModel.selectedNode == nil)
    #expect(viewModel.selectedGroup == nil)
    #expect(viewModel.selectedEdge == nil)
    #expect(viewModel.selectedTitle == "Canvas")
  }
}

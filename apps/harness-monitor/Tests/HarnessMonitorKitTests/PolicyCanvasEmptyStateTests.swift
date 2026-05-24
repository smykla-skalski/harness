import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas empty state")
@MainActor
struct PolicyCanvasEmptyStateTests {
  @Test("canvas with no nodes and no groups reports empty")
  func emptyWithoutNodesOrGroups() {
    let viewModel = PolicyCanvasViewModel(
      nodes: [],
      groups: [],
      edges: [],
      selection: nil,
      zoom: 1
    )
    #expect(viewModel.isEmpty)
  }

  @Test("canvas with only groups (no nodes) is not empty")
  func notEmptyWhenOnlyGroupsExist() {
    let group = PolicyCanvasGroup(
      id: "group-a",
      title: "Group",
      frame: CGRect(x: 80, y: 80, width: 240, height: 180),
      tone: .intake
    )
    let viewModel = PolicyCanvasViewModel(
      nodes: [],
      groups: [group],
      edges: [],
      selection: nil,
      zoom: 1
    )
    #expect(!viewModel.isEmpty)
  }

  @Test("canvas with only nodes (no groups) is not empty")
  func notEmptyWhenOnlyNodesExist() {
    let node = PolicyCanvasNode(
      id: "node-a",
      title: "Node",
      kind: .source,
      position: CGPoint(x: 120, y: 120)
    )
    let viewModel = PolicyCanvasViewModel(
      nodes: [node],
      groups: [],
      edges: [],
      selection: nil,
      zoom: 1
    )
    #expect(!viewModel.isEmpty)
  }

  @Test("creating a node clears the empty state")
  func createNodeClearsEmptyState() {
    let viewModel = PolicyCanvasViewModel(
      nodes: [],
      groups: [],
      edges: [],
      selection: nil,
      zoom: 1
    )
    #expect(viewModel.isEmpty)

    viewModel.createNode(kind: .source, at: CGPoint(x: 200, y: 200))

    #expect(!viewModel.isEmpty)
  }

  @Test("palette drop on empty canvas clears the empty state")
  func paletteDropClearsEmptyState() {
    let viewModel = PolicyCanvasViewModel(
      nodes: [],
      groups: [],
      edges: [],
      selection: nil,
      zoom: 1
    )
    let payload = viewModel.palettePayload(for: .source)

    let dropped = viewModel.dropPalettePayloads([payload], at: CGPoint(x: 200, y: 200))

    #expect(dropped)
    #expect(!viewModel.isEmpty)
  }

  @Test("deleting the last node restores empty state")
  func deletingLastNodeRestoresEmptyState() {
    let viewModel = PolicyCanvasViewModel(
      nodes: [],
      groups: [],
      edges: [],
      selection: nil,
      zoom: 1
    )
    viewModel.createNode(kind: .source, at: CGPoint(x: 200, y: 200))
    guard case .node(let id) = viewModel.selection else {
      Issue.record("Expected selection on the freshly created node")
      return
    }

    let request = viewModel.deleteSelectedComponent()
    if let request {
      viewModel.confirmDelete(request)
    }

    #expect(viewModel.node(id) == nil)
    #expect(viewModel.isEmpty)
  }
}

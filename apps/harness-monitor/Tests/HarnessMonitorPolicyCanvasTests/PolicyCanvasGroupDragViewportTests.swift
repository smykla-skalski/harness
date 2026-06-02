import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Wave 3M P48 follow-up: locks the document-vs-viewport dirty boundary on the
/// group-drag gesture. Sibling file to PolicyCanvasGroupDragTests.swift (wave
/// 1C) which already covers translation accumulation, member co-motion, and
/// drag-state reentrance — this file fills the dirty-flag gap.
@Suite("Policy canvas group drag — viewport state")
@MainActor
struct PolicyCanvasGroupDragViewportTests {
  @Test("endGroupDrag leaves documentDirty true exactly once after a clean baseline")
  func endGroupDragFlipsDocumentDirtyOnce() {
    let viewModel = makeAlignedCanvas()
    #expect(viewModel.documentDirty == false)

    viewModel.dragGroup("group-A", translation: CGSize(width: 40, height: 20))
    viewModel.endGroupDrag("group-A", translation: CGSize(width: 40, height: 20))

    #expect(viewModel.documentDirty == true)
  }

  @Test("group drag does not touch viewportDirty")
  func groupDragLeavesViewportDirtyAlone() {
    let viewModel = makeAlignedCanvas()
    // Baseline: viewportDirty starts false; group drag is a document mutation
    // (it moves nodes/groups, which round-trip through exportDocument), not a
    // viewport pan/zoom. The dirty channels are separate so save/promote
    // gates do not pick up window-side state changes.
    #expect(viewModel.viewportDirty == false)

    viewModel.dragGroup("group-A", translation: CGSize(width: 60, height: 0))
    #expect(viewModel.viewportDirty == false)

    viewModel.endGroupDrag("group-A", translation: CGSize(width: 60, height: 0))
    #expect(viewModel.viewportDirty == false)
  }

  @Test("group drag selects the group during the gesture")
  func groupDragSelectsGroupDuringGesture() {
    let viewModel = makeAlignedCanvas()
    viewModel.select(nil)
    #expect(viewModel.selection == nil)

    viewModel.dragGroup("group-A", translation: CGSize(width: 20, height: 0))

    #expect(viewModel.selection == .group("group-A"))
    #expect(viewModel.selectedGroup?.id == "group-A")
  }

  // MARK: - Helpers

  /// Mirrors the shape of `PolicyCanvasGroupDragTests.makeAlignedCanvas` —
  /// grid-aligned positions and zoom=1.0 so drag math is exact and dirty
  /// flags surface predictably.
  private func makeAlignedCanvas() -> PolicyCanvasViewModel {
    var n1 = PolicyCanvasNode(
      id: "node-1",
      title: "One",
      kind: .source,
      position: CGPoint(x: 100, y: 100)
    )
    n1.groupID = "group-A"
    var n2 = PolicyCanvasNode(
      id: "node-2",
      title: "Two",
      kind: .condition,
      position: CGPoint(x: 260, y: 100)
    )
    n2.groupID = "group-A"

    let group = PolicyCanvasGroup(
      id: "group-A",
      title: "Group A",
      frame: CGRect(x: 80, y: 80, width: 360, height: 200),
      tone: .intake
    )

    return PolicyCanvasViewModel(
      nodes: [n1, n2],
      groups: [group],
      edges: [],
      selection: nil,
      zoom: 1
    )
  }
}

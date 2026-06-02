import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas group drag")
@MainActor
struct PolicyCanvasGroupDragTests {
  @Test("group drag snaps origin and moves member nodes together")
  func groupDragMovesMemberNodesTogether() {
    let viewModel = makeAlignedCanvas()
    let groupID = "group-A"
    let memberIDs = viewModel.nodes(in: groupID).map(\.id)
    #expect(memberIDs.sorted() == ["node-1", "node-2"])
    let originFrame = viewModel.group(groupID)?.frame ?? .zero
    let originPositions = capturedPositions(in: viewModel, ids: memberIDs)

    // zoom is 1.0 here; (40, 20) translates and snaps cleanly to grid (20pt)
    viewModel.dragGroup(groupID, translation: CGSize(width: 40, height: 20))

    let moved = viewModel.group(groupID)?.frame.origin ?? .zero
    let deltaX = moved.x - originFrame.origin.x
    let deltaY = moved.y - originFrame.origin.y
    #expect(deltaX == 40)
    #expect(deltaY == 20)

    for id in memberIDs {
      let before = originPositions[id] ?? .zero
      let after = viewModel.node(id)?.position ?? .zero
      #expect(after.x - before.x == deltaX)
      #expect(after.y - before.y == deltaY)
    }
    #expect(viewModel.documentDirty)
    #expect(viewModel.selection == .group(groupID))
    #expect(viewModel.highlightedGroupID == groupID)
  }

  @Test("group drag does not move nodes outside the group")
  func groupDragLeavesOutsideNodesAlone() {
    let viewModel = makeAlignedCanvas()
    let outsideID = "node-outside"
    let originalOutside = viewModel.node(outsideID)?.position ?? .zero

    viewModel.dragGroup("group-A", translation: CGSize(width: 80, height: 40))

    let after = viewModel.node(outsideID)?.position ?? .zero
    #expect(after == originalOutside)
  }

  @Test("repeated drags compute translation from cached origin, not last frame")
  func repeatedGroupDragUsesCachedOrigin() {
    let viewModel = makeAlignedCanvas()
    let groupID = "group-A"
    let originFrame = viewModel.group(groupID)?.frame ?? .zero

    viewModel.dragGroup(groupID, translation: CGSize(width: 20, height: 0))
    viewModel.dragGroup(groupID, translation: CGSize(width: 60, height: 0))

    let moved = viewModel.group(groupID)?.frame.origin ?? .zero
    #expect(moved.x == originFrame.origin.x + 60)
    #expect(moved.y == originFrame.origin.y)
  }

  @Test("endGroupDrag clears caches so a new drag re-seeds origin")
  func endGroupDragClearsState() {
    let viewModel = makeAlignedCanvas()
    let groupID = "group-A"

    viewModel.dragGroup(groupID, translation: CGSize(width: 40, height: 20))
    viewModel.endGroupDrag(groupID, translation: CGSize(width: 40, height: 20))
    let restingFrame = viewModel.group(groupID)?.frame.origin ?? .zero
    #expect(viewModel.highlightedGroupID == nil)

    // A fresh drag with zero translation reseeds the origin and leaves the group put.
    viewModel.dragGroup(groupID, translation: .zero)
    let afterZeroDrag = viewModel.group(groupID)?.frame.origin ?? .zero
    #expect(afterZeroDrag == restingFrame)

    // And a follow-up small drag moves by exactly that translation, not cumulatively.
    viewModel.dragGroup(groupID, translation: CGSize(width: 20, height: 0))
    let afterSecondDrag = viewModel.group(groupID)?.frame.origin ?? .zero
    #expect(afterSecondDrag.x == restingFrame.x + 20)
    #expect(afterSecondDrag.y == restingFrame.y)
  }

  @Test("group drag with zero translation does not move grid-aligned members")
  func groupDragZeroTranslationIsNoOp() {
    let viewModel = makeAlignedCanvas()
    let groupID = "group-A"
    let memberIDs = viewModel.nodes(in: groupID).map(\.id)
    let before = capturedPositions(in: viewModel, ids: memberIDs)
    let frameBefore = viewModel.group(groupID)?.frame ?? .zero

    viewModel.dragGroup(groupID, translation: .zero)

    for id in memberIDs {
      #expect(viewModel.node(id)?.position == before[id])
    }
    #expect(viewModel.group(groupID)?.frame == frameBefore)
  }

  @Test("group drag for unknown id is a no-op")
  func unknownGroupDragIsNoOp() {
    let viewModel = makeAlignedCanvas()
    let groupSnapshot = viewModel.groups.map(\.frame)
    let nodeSnapshot = viewModel.nodes.map(\.position)
    let dirtyBefore = viewModel.documentDirty

    viewModel.dragGroup("does-not-exist", translation: CGSize(width: 100, height: 100))

    #expect(viewModel.groups.map(\.frame) == groupSnapshot)
    #expect(viewModel.nodes.map(\.position) == nodeSnapshot)
    #expect(viewModel.documentDirty == dirtyBefore)
  }

  @Test("node drag in a large grouped canvas stays under the interaction budget")
  func largeGroupedNodeDragPerformance() {
    let viewModel = makeLargeGroupedCanvas(groupCount: 180, nodesPerGroup: 6)
    let draggedNodeID = "group-90-node-3"
    let start = Date()

    for tick in 0..<120 {
      viewModel.dragNode(
        draggedNodeID,
        translation: CGSize(width: CGFloat(tick * 20), height: CGFloat((tick % 7) * 20))
      )
    }

    let elapsed = Date().timeIntervalSince(start)
    #expect(
      elapsed < 0.2,
      "Large grouped node drag took \(elapsed * 1000)ms, expected <200ms"
    )
  }

  // MARK: - Helpers

  /// Builds a canvas with grid-aligned positions and zoom=1.0 so drag math is exact.
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
    var outside = PolicyCanvasNode(
      id: "node-outside",
      title: "Outside",
      kind: .decision,
      position: CGPoint(x: 700, y: 100)
    )
    outside.groupID = nil

    let group = PolicyCanvasGroup(
      id: "group-A",
      title: "Group A",
      frame: CGRect(x: 80, y: 80, width: 360, height: 200),
      tone: .intake
    )

    return PolicyCanvasViewModel(
      nodes: [n1, n2, outside],
      groups: [group],
      edges: [],
      selection: nil,
      zoom: 1
    )
  }

  private func makeLargeGroupedCanvas(
    groupCount: Int,
    nodesPerGroup: Int
  ) -> PolicyCanvasViewModel {
    var nodes: [PolicyCanvasNode] = []
    var groups: [PolicyCanvasGroup] = []
    nodes.reserveCapacity(groupCount * nodesPerGroup)
    groups.reserveCapacity(groupCount)

    for groupIndex in 0..<groupCount {
      let groupID = "group-\(groupIndex)"
      let column = groupIndex % 12
      let row = groupIndex / 12
      let origin = CGPoint(
        x: CGFloat(column) * 420,
        y: CGFloat(row) * 320
      )
      groups.append(
        PolicyCanvasGroup(
          id: groupID,
          title: "Group \(groupIndex)",
          frame: CGRect(origin: origin, size: CGSize(width: 360, height: 220)),
          tone: .intake
        )
      )

      for nodeIndex in 0..<nodesPerGroup {
        var node = PolicyCanvasNode(
          id: "\(groupID)-node-\(nodeIndex)",
          title: "Node \(nodeIndex)",
          kind: .condition,
          position: CGPoint(
            x: origin.x + 40 + CGFloat(nodeIndex % 3) * 120,
            y: origin.y + 50 + CGFloat(nodeIndex / 3) * 100
          )
        )
        node.groupID = groupID
        nodes.append(node)
      }
    }

    return PolicyCanvasViewModel(
      nodes: nodes,
      groups: groups,
      edges: [],
      selection: nil,
      zoom: 1
    )
  }

  private func capturedPositions(
    in viewModel: PolicyCanvasViewModel,
    ids: [String]
  ) -> [String: CGPoint] {
    Dictionary(
      uniqueKeysWithValues: ids.compactMap { id -> (String, CGPoint)? in
        guard let node = viewModel.node(id) else {
          return nil
        }
        return (id, node.position)
      }
    )
  }
}

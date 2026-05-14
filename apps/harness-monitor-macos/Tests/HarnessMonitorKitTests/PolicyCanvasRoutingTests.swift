import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas routing")
@MainActor
struct PolicyCanvasRoutingTests {
  @Test("inter-group edge route avoids middle group")
  func interGroupEdgeRouteAvoidsMiddleGroup() {
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 572, y: 360),
      target: CGPoint(x: 1_484, y: 360),
      lane: 0,
      groups: defaultGroups,
      sourceGroupID: "entry",
      targetGroupID: "terminal"
    )

    #expect(!route.segmentsIntersect(rect: mergeGroup.frame))
    #expect(route.labelPosition.y == route.points[2].y)
  }

  @Test("blocked routes reserve separate label lanes")
  func blockedRoutesReserveSeparateLabelLanes() {
    let labels = (0..<3).map { lane in
      PolicyCanvasEdgeRoute(
        source: CGPoint(x: 572, y: 336 + CGFloat(lane * 24)),
        target: CGPoint(x: 1_484, y: 360 + CGFloat(lane * 140)),
        lane: lane,
        groups: defaultGroups,
        sourceGroupID: "entry",
        targetGroupID: "terminal"
      ).labelPosition
    }

    let sortedLabelY = labels.map(\.y).sorted()
    #expect(Set(sortedLabelY.map { Int($0.rounded()) }).count == labels.count)
    #expect(labelsHaveBadgeClearance(sortedLabelY))
  }

  @Test("adjacent group routes use gap corridor")
  func adjacentGroupRoutesUseGapCorridor() {
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 972, y: 360),
      target: CGPoint(x: 1_484, y: 1_012),
      lane: 8,
      groups: [mergeGroup, terminalGroup],
      sourceGroupID: "merge",
      targetGroupID: "terminal"
    )

    let verticalCorridorX = route.points[3].x
    #expect(verticalCorridorX > mergeGroup.frame.maxX)
    #expect(verticalCorridorX < terminalGroup.frame.minX)
  }

  @Test("adjacent group routes reserve badge clearance")
  func adjacentGroupRoutesReserveBadgeClearance() {
    let labelYs = (0..<3).map { lane in
      PolicyCanvasEdgeRoute(
        source: CGPoint(x: 972, y: 360),
        target: CGPoint(x: 1_484, y: 1_012),
        lane: lane,
        groups: [mergeGroup, terminalGroup],
        sourceGroupID: "merge",
        targetGroupID: "terminal"
      ).labelPosition.y
    }.sorted()

    #expect(labelsHaveBadgeClearance(labelYs))
  }

  @Test("same group return routes keep labels outside nodes")
  func sameGroupReturnRoutesKeepLabelsOutsideNodes() {
    let sourceNode = CGRect(x: 804, y: 312, width: 168, height: 96)
    let targetNode = CGRect(x: 804, y: 492, width: 168, height: 96)
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: sourceNode.maxX, y: sourceNode.midY),
      target: CGPoint(x: targetNode.minX, y: targetNode.midY),
      lane: 4,
      groups: [mergeGroup],
      sourceGroupID: "merge",
      targetGroupID: "merge"
    )

    #expect(!edgeLabelFrame(route.labelPosition).intersects(sourceNode))
    #expect(!edgeLabelFrame(route.labelPosition).intersects(targetNode))
    #expect(route.labelPosition.x > sourceNode.maxX)
  }

  private var defaultGroups: [PolicyCanvasGroup] {
    [entryGroup, mergeGroup, terminalGroup]
  }

  private var entryGroup: PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: "entry",
      title: "Action routing",
      frame: CGRect(x: 360, y: 260, width: 256, height: 220),
      tone: .intake
    )
  }

  private var mergeGroup: PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: "merge",
      title: "Merge checks",
      frame: CGRect(x: 760, y: 260, width: 256, height: 420),
      tone: .evaluation
    )
  }

  private var terminalGroup: PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: "terminal",
      title: "Terminal decisions",
      frame: CGRect(x: 1_440, y: 260, width: 256, height: 1_220),
      tone: .release
    )
  }

  private func labelsHaveBadgeClearance(_ sortedYs: [CGFloat]) -> Bool {
    zip(sortedYs, sortedYs.dropFirst()).allSatisfy { previous, next in
      next - previous >= PolicyCanvasLayout.edgeLabelHeight + 6
    }
  }

  private func edgeLabelFrame(_ position: CGPoint) -> CGRect {
    CGRect(
      x: position.x - PolicyCanvasLayout.edgeLabelMaxWidth / 2,
      y: position.y - PolicyCanvasLayout.edgeLabelHeight / 2,
      width: PolicyCanvasLayout.edgeLabelMaxWidth,
      height: PolicyCanvasLayout.edgeLabelHeight
    )
  }
}

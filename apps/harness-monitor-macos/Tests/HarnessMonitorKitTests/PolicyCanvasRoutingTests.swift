import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas routing")
@MainActor
struct PolicyCanvasRoutingTests {
  @Test("inter-group edge route avoids middle group")
  func interGroupEdgeRouteAvoidsMiddleGroup() {
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 352, y: 260),
      target: CGPoint(x: 1_024, y: 260),
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
        source: CGPoint(x: 352, y: 236 + CGFloat(lane * 24)),
        target: CGPoint(x: 1_024, y: 260 + CGFloat(lane * 140)),
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
      source: CGPoint(x: 752, y: 260),
      target: CGPoint(x: 1_024, y: 912),
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
        source: CGPoint(x: 752, y: 260),
        target: CGPoint(x: 1_024, y: 912),
        lane: lane,
        groups: [mergeGroup, terminalGroup],
        sourceGroupID: "merge",
        targetGroupID: "terminal"
      ).labelPosition.y
    }.sorted()

    #expect(labelsHaveBadgeClearance(labelYs))
  }

  private var defaultGroups: [PolicyCanvasGroup] {
    [entryGroup, mergeGroup, terminalGroup]
  }

  private var entryGroup: PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: "entry",
      title: "Action routing",
      frame: CGRect(x: 140, y: 160, width: 256, height: 220),
      tone: .intake
    )
  }

  private var mergeGroup: PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: "merge",
      title: "Merge checks",
      frame: CGRect(x: 540, y: 160, width: 256, height: 420),
      tone: .evaluation
    )
  }

  private var terminalGroup: PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: "terminal",
      title: "Terminal decisions",
      frame: CGRect(x: 980, y: 160, width: 256, height: 1_220),
      tone: .release
    )
  }

  private func labelsHaveBadgeClearance(_ sortedYs: [CGFloat]) -> Bool {
    zip(sortedYs, sortedYs.dropFirst()).allSatisfy { previous, next in
      next - previous >= 30
    }
  }
}

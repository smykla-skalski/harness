import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasRoutingTests {
  // Edges that carry the same words ("action in") are not grouped - each label
  // belongs on its own route. The placement keeps labels on horizontal runs
  // (the user's rule: labels sit on horizontal edges unless that is impossible)
  // rather than pushing duplicates onto their vertical feeders. With three
  // separate horizontal trunks 40pt apart there is room for every label on its
  // own trunk, so each rests on a horizontal run and none overlap.
  @Test("display duplicate labels rest on their own horizontal runs")
  func displayDuplicateLabelsRestOnTheirHorizontalRuns() {
    let labelSize = CGSize(width: 72, height: PolicyCanvasLayout.edgeLabelHeight)
    let routes = [
      PolicyCanvasLabelPlacementRoute(
        id: "edge-a",
        label: "action in",
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 40),
            CGPoint(x: 80, y: 40),
            CGPoint(x: 80, y: 220),
            CGPoint(x: 360, y: 220),
          ],
          labelPosition: CGPoint(x: 220, y: 220)
        ),
        size: labelSize
      ),
      PolicyCanvasLabelPlacementRoute(
        id: "edge-b",
        label: "action in",
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 88),
            CGPoint(x: 120, y: 88),
            CGPoint(x: 120, y: 260),
            CGPoint(x: 360, y: 260),
          ],
          labelPosition: CGPoint(x: 240, y: 260)
        ),
        size: labelSize
      ),
      PolicyCanvasLabelPlacementRoute(
        id: "edge-c",
        label: "action in",
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 136),
            CGPoint(x: 160, y: 136),
            CGPoint(x: 160, y: 300),
            CGPoint(x: 360, y: 300),
          ],
          labelPosition: CGPoint(x: 260, y: 300)
        ),
        size: labelSize
      ),
    ]
    let positions = policyCanvasResolvedLabelPositions(
      routes: routes,
      nodeFrames: [],
      routeFrames: policyCanvasRouteFrames(routes)
    )

    for route in routes {
      guard let center = positions[route.id] else {
        Issue.record("expected a label position for \(route.id)")
        continue
      }
      #expect(
        labelRestsOnHorizontalRun(center: center, route: route.route),
        "\(route.id) label is not on a horizontal run"
      )
    }

    let frames = routes.compactMap { route in
      positions[route.id].map { edgeLabelFrame($0, size: route.size) }
    }
    for left in 0..<frames.count {
      for right in (left + 1)..<frames.count where frames[left].intersects(frames[right]) {
        Issue.record("duplicate labels \(routes[left].id) and \(routes[right].id) overlap")
      }
    }
  }

  private func labelRestsOnHorizontalRun(
    center: CGPoint,
    route: PolicyCanvasEdgeRoute
  ) -> Bool {
    for (start, end) in zip(route.points, route.points.dropFirst()) {
      guard abs(start.y - end.y) < 0.5, abs(start.x - end.x) > 0.5 else {
        continue
      }
      if abs(center.y - start.y) < 1,
        (min(start.x, end.x) - 1)...(max(start.x, end.x) + 1) ~= center.x
      {
        return true
      }
    }
    return false
  }

  @Test("display duplicate labels avoid shared vertical trunks")
  func displayDuplicateLabelsAvoidSharedVerticalTrunks() {
    let label = "evidence failure"
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let labelSize = metrics.size(for: label)
    let routes = [
      PolicyCanvasLabelPlacementRoute(
        id: "edge-a",
        label: label,
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 32),
            CGPoint(x: 120, y: 32),
            CGPoint(x: 120, y: 220),
            CGPoint(x: 220, y: 220),
          ],
          labelPosition: CGPoint(x: 120, y: 150)
        ),
        size: labelSize
      ),
      PolicyCanvasLabelPlacementRoute(
        id: "edge-b",
        label: label,
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 32, y: 80),
            CGPoint(x: 120, y: 80),
            CGPoint(x: 120, y: 220),
            CGPoint(x: 260, y: 220),
          ],
          labelPosition: CGPoint(x: 120, y: 160)
        ),
        size: labelSize
      ),
      PolicyCanvasLabelPlacementRoute(
        id: "edge-c",
        label: label,
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 64, y: 128),
            CGPoint(x: 120, y: 128),
            CGPoint(x: 120, y: 220),
            CGPoint(x: 300, y: 220),
          ],
          labelPosition: CGPoint(x: 120, y: 170)
        ),
        size: labelSize
      ),
    ]
    let positions = policyCanvasResolvedLabelPositions(
      routes: routes,
      nodeFrames: [],
      routeFrames: policyCanvasRouteFrames(routes)
    )

    let sharedVerticalTrunk = CGRect(x: 110, y: 80, width: 20, height: 140)
    let labelsOnTrunk = routes.compactMap { route in
      positions[route.id].map {
        edgeLabelFrame($0, size: route.size)
      }
    }.filter { $0.intersects(sharedVerticalTrunk) }

    #expect(labelsOnTrunk.count <= 1)
    #expect(labelsOnTrunk.count < routes.count)
  }

  var defaultGroups: [PolicyCanvasGroup] {
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

  var mergeGroup: PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: "merge",
      title: "Merge checks",
      frame: CGRect(x: 760, y: 260, width: 256, height: 420),
      tone: .evaluation
    )
  }

  var terminalGroup: PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: "terminal",
      title: "Terminal decisions",
      frame: CGRect(x: 1_900, y: 480, width: 256, height: 1_220),
      tone: .release
    )
  }
}

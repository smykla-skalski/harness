import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas clearance correctness fixes")
struct PolicyCanvasClearanceFixesTests {
  @Test("artifact penalty ignores bridge endpoint segments")
  func artifactPenaltyIgnoresBridgeEndpoints() {
    // 6-point route: tiny 4pt port stub at source, riser, long bus, riser,
    // tiny 4pt port stub at target. policyCanvasInteriorRouteSegments
    // excludes the first/last segments (the port stubs), so only the bus
    // and risers participate in the penalty check.
    let points: [CGPoint] = [
      CGPoint(x: 0, y: 100),
      CGPoint(x: 4, y: 100),
      CGPoint(x: 4, y: 90),
      CGPoint(x: 200, y: 90),
      CGPoint(x: 200, y: 100),
      CGPoint(x: 204, y: 100),
    ]
    let route = PolicyCanvasEdgeRoute(points: points, labelPosition: .zero)
    let penalty = policyCanvasRouteArtifactPenalty(route, minimumSpacing: 20)
    #expect(penalty == 0, "Bridge endpoint segments should not incur penalty")
  }

  @Test("artifact penalty still fires on a tiny interior segment")
  func artifactPenaltyFiresOnInteriorTinySegment() {
    // Six-point route where segments 2 and 3 are interior. Segment 2 is
    // shorter than minimumSegmentLength so the penalty should fire.
    let points: [CGPoint] = [
      CGPoint(x: 0, y: 100),
      CGPoint(x: 40, y: 100),
      CGPoint(x: 40, y: 102),
      CGPoint(x: 200, y: 102),
      CGPoint(x: 200, y: 100),
      CGPoint(x: 240, y: 100),
    ]
    let route = PolicyCanvasEdgeRoute(points: points, labelPosition: .zero)
    let penalty = policyCanvasRouteArtifactPenalty(route, minimumSpacing: 20)
    #expect(penalty > 0, "Interior short segment should incur penalty")
  }
}

@Suite("Policy canvas corridor key derivation")
struct PolicyCanvasCorridorKeyDerivationTests {
  @Test("missing hint yields nil key")
  func missingHintYieldsNilKey() {
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 100, y: 0),
      ],
      labelPosition: .zero
    )
    let key = PolicyCanvasPreparedRouteInput.policyCanvasCorridorKey(
      forRoute: route,
      hint: nil,
      lineSpacing: 19.2
    )
    #expect(key == nil)
  }

  @Test("two routes with similar dominant lane y derive same key")
  func sameDominantYDerivesSameKey() {
    let routeA = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 10, y: 0),
        CGPoint(x: 10, y: 200),
        CGPoint(x: 90, y: 200),
        CGPoint(x: 90, y: 0),
        CGPoint(x: 100, y: 0),
      ],
      labelPosition: .zero
    )
    let routeB = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 10, y: 0),
        CGPoint(x: 10, y: 201),
        CGPoint(x: 90, y: 201),
        CGPoint(x: 90, y: 0),
        CGPoint(x: 100, y: 0),
      ],
      labelPosition: .zero
    )
    let hint = PolicyCanvasEdgeCorridorHint(
      key: PolicyCanvasRouteCorridorKey(
        sourceScopeID: "s",
        targetScopeID: "t",
        targetNodeID: "target",
        label: "label",
        laneIndex: 0
      ),
      horizontalLaneY: 200,
      verticalLaneX: nil
    )
    let keyA = PolicyCanvasPreparedRouteInput.policyCanvasCorridorKey(
      forRoute: routeA,
      hint: hint,
      lineSpacing: 19.2
    )
    let keyB = PolicyCanvasPreparedRouteInput.policyCanvasCorridorKey(
      forRoute: routeB,
      hint: hint,
      lineSpacing: 19.2
    )
    #expect(keyA == keyB)
  }

  @Test("two routes with distant dominant lane y derive different keys")
  func distantDominantYDerivesDifferentKeys() {
    let routeNear = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 10, y: 0),
        CGPoint(x: 10, y: 200),
        CGPoint(x: 90, y: 200),
        CGPoint(x: 90, y: 0),
        CGPoint(x: 100, y: 0),
      ],
      labelPosition: .zero
    )
    let routeFar = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 10, y: 0),
        CGPoint(x: 10, y: 400),
        CGPoint(x: 90, y: 400),
        CGPoint(x: 90, y: 0),
        CGPoint(x: 100, y: 0),
      ],
      labelPosition: .zero
    )
    let hint = PolicyCanvasEdgeCorridorHint(
      key: PolicyCanvasRouteCorridorKey(
        sourceScopeID: "s",
        targetScopeID: "t",
        targetNodeID: "target",
        label: "label",
        laneIndex: 0
      ),
      horizontalLaneY: 200,
      verticalLaneX: nil
    )
    let keyNear = PolicyCanvasPreparedRouteInput.policyCanvasCorridorKey(
      forRoute: routeNear,
      hint: hint,
      lineSpacing: 19.2
    )
    let keyFar = PolicyCanvasPreparedRouteInput.policyCanvasCorridorKey(
      forRoute: routeFar,
      hint: hint,
      lineSpacing: 19.2
    )
    #expect(keyNear != keyFar)
  }
}

import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas minimap")
struct PolicyCanvasMinimapTests {
  @Test("minimap world bounds include viewport excursions outside the routed graph")
  func minimapWorldBoundsIncludeViewportExcursionsOutsideTheRoutedGraph() {
    let snapshot = policyCanvasMinimapSnapshot(
      contentBounds: CGRect(x: 200, y: 100, width: 800, height: 500),
      viewportRect: CGRect(x: -120, y: 140, width: 400, height: 240),
      nodeFrames: [],
      groupFrames: []
    )

    #expect(snapshot.contentBounds == CGRect(x: 200, y: 100, width: 800, height: 500))
    #expect(snapshot.worldBounds == CGRect(x: -120, y: 100, width: 1_120, height: 500))
  }

  @Test("minimap projection preserves the real policy bounds inside a larger world")
  func minimapProjectionPreservesRealPolicyBoundsInsideALargerWorld() {
    let snapshot = policyCanvasMinimapSnapshot(
      contentBounds: CGRect(x: 200, y: 50, width: 600, height: 400),
      viewportRect: CGRect(x: -100, y: 0, width: 1_000, height: 500),
      nodeFrames: [],
      groupFrames: []
    )
    let projection = policyCanvasMinimapProjection(
      snapshot: snapshot,
      minimapSize: CGSize(width: 200, height: 100)
    )

    #expect(
      projection.rect(forCanvasRect: snapshot.contentBounds)
        == CGRect(x: 60, y: 10, width: 120, height: 80)
    )
  }

  @Test("minimap centers the viewport rect on the policy content bounds")
  func minimapCentersViewportRectOnPolicyContentBounds() {
    let snapshot = policyCanvasMinimapSnapshot(
      contentBounds: CGRect(x: 200, y: 100, width: 800, height: 400),
      viewportRect: CGRect(x: 0, y: 0, width: 300, height: 200),
      nodeFrames: [],
      groupFrames: []
    )

    // Content center is (600, 300); a 300x200 viewport centered there starts at
    // (600 - 150, 300 - 100) = (450, 200), independent of where the click landed.
    #expect(snapshot.viewportOriginCenteredOnContent == CGPoint(x: 450, y: 200))
  }

  @Test("minimap treats a near-zero drag as a recentering click and a longer drag as a pan")
  func minimapTreatsNearZeroDragAsClick() {
    #expect(policyCanvasMinimapGestureIsClick(translation: .zero))
    #expect(policyCanvasMinimapGestureIsClick(translation: CGSize(width: 2, height: 2)))
    #expect(!policyCanvasMinimapGestureIsClick(translation: CGSize(width: 12, height: 9)))
  }

  @Test("minimap projection scales viewport rectangles and drag translations consistently")
  func minimapProjectionScalesViewportRectanglesAndDragTranslationsConsistently() {
    let snapshot = PolicyCanvasMinimapSnapshot(
      contentBounds: CGRect(x: 200, y: 100, width: 800, height: 400),
      worldBounds: CGRect(x: 200, y: 100, width: 800, height: 400),
      nodeFrames: [],
      groupFrames: [],
      viewportRect: CGRect(x: 400, y: 200, width: 200, height: 100)
    )
    let projection = policyCanvasMinimapProjection(
      snapshot: snapshot,
      minimapSize: CGSize(width: 200, height: 100)
    )

    #expect(projection.scale == 0.25)
    #expect(
      projection.rect(forCanvasRect: snapshot.viewportRect)
        == CGRect(x: 50, y: 25, width: 50, height: 25)
    )
    #expect(
      projection.canvasTranslation(forMinimapTranslation: CGSize(width: 20, height: 10))
        == CGSize(width: 80, height: 40)
    )
  }
}

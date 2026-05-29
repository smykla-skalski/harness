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

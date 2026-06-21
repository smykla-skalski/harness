import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas minimap")
struct PolicyCanvasMinimapTests {
  @Test("minimap world bounds stay pinned to the policy content regardless of the viewport")
  func minimapWorldBoundsStayPinnedToPolicyContentRegardlessOfTheViewport() {
    let content = CGRect(x: 200, y: 100, width: 800, height: 500)
    let viewportInside = policyCanvasMinimapSnapshot(
      contentBounds: content,
      viewportRect: CGRect(x: 300, y: 150, width: 200, height: 120),
      nodeFrames: [],
      groupFrames: []
    )
    let viewportOutside = policyCanvasMinimapSnapshot(
      contentBounds: content,
      viewportRect: CGRect(x: -120, y: 140, width: 400, height: 240),
      nodeFrames: [],
      groupFrames: []
    )

    // The world is the content alone - it never expands to include the viewport,
    // so resizing or panning the viewport leaves the thumbnail projection
    // untouched. Toggling the inspector pane therefore cannot rescale the graph.
    #expect(viewportInside.contentBounds == content)
    #expect(viewportInside.worldBounds == content)
    #expect(viewportOutside.worldBounds == viewportInside.worldBounds)
  }

  @Test("minimap graph projection ignores the viewport so the thumbnail never rescales")
  func minimapGraphProjectionIgnoresViewportSoThumbnailNeverRescales() {
    let content = CGRect(x: 200, y: 50, width: 600, height: 400)
    let wideViewport = policyCanvasMinimapSnapshot(
      contentBounds: content,
      viewportRect: CGRect(x: -100, y: 0, width: 1_000, height: 500),
      nodeFrames: [],
      groupFrames: []
    )
    let narrowViewport = policyCanvasMinimapSnapshot(
      contentBounds: content,
      viewportRect: CGRect(x: 250, y: 80, width: 200, height: 150),
      nodeFrames: [],
      groupFrames: []
    )
    let minimapSize = CGSize(width: 200, height: 100)
    let wideProjection = policyCanvasMinimapProjection(
      snapshot: wideViewport,
      minimapSize: minimapSize
    )
    let narrowProjection = policyCanvasMinimapProjection(
      snapshot: narrowViewport,
      minimapSize: minimapSize
    )

    // Same content + same minimap size => identical projected content frame, no
    // matter how the viewport differs. scale = min(200/600, 100/400) = 0.25, so
    // the 600x400 content fits to 150x100 centered in the 200x100 minimap.
    #expect(
      wideProjection.rect(forCanvasRect: content)
        == narrowProjection.rect(forCanvasRect: content)
    )
    #expect(
      wideProjection.rect(forCanvasRect: content)
        == CGRect(x: 25, y: 0, width: 150, height: 100)
    )
  }

  @Test("minimap viewport indicator clamps to the minimap bounds when it leaves the content")
  func minimapViewportIndicatorClampsToMinimapBoundsWhenItLeavesTheContent() {
    let minimapSize = CGSize(width: 200, height: 100)

    // Fully inside the minimap -> returned unchanged.
    #expect(
      policyCanvasMinimapClampedViewportIndicator(
        CGRect(x: 40, y: 30, width: 60, height: 40),
        in: minimapSize
      ) == CGRect(x: 40, y: 30, width: 60, height: 40)
    )

    // Larger than the minimap -> capped to the minimap and centered.
    #expect(
      policyCanvasMinimapClampedViewportIndicator(
        CGRect(x: -40, y: -20, width: 300, height: 160),
        in: minimapSize
      ) == CGRect(x: 0, y: 0, width: 200, height: 100)
    )

    // Panned off the right edge -> stuck against the edge, size preserved.
    #expect(
      policyCanvasMinimapClampedViewportIndicator(
        CGRect(x: 320, y: 20, width: 40, height: 30),
        in: minimapSize
      ) == CGRect(x: 160, y: 20, width: 40, height: 30)
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
    // (600 - 150, 300 - 100) = (450, 200).
    #expect(snapshot.viewportOriginCenteredOnContent == CGPoint(x: 450, y: 200))
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

  @Test("minimap centering mode supports button and viewport click recentering")
  func minimapCenteringModeSupportsButtonAndViewportClickRecentering() throws {
    let source = try previewableSourceFile(named: "PolicyCanvasMinimapOverlay.swift")

    #expect(source.contains("@AppStorage(PolicyCanvasMinimapDefaults.centeringModeKey)"))
    #expect(source.contains("PolicyCanvasMinimapCenteringMode.defaultValue"))
    #expect(source.contains("if minimapCenteringMode.showsCenterButton"))
    #expect(source.contains("Image(systemName: \"dot.scope\")"))
    #expect(source.contains("onViewportDrag(snapshot.viewportOriginCenteredOnContent)"))
    #expect(source.contains("PolicyCanvasMinimapCenterButtonStyle"))
    #expect(source.contains("HarnessMonitorAccessibility.policyCanvasMinimapCenterButton"))
    #expect(source.contains("if minimapCenteringMode.recentersOnViewportClick"))
    #expect(source.contains("policyCanvasMinimapGestureIsClick(translation: value.translation)"))
  }

  @Test("minimap viewport keeps only the active drag cursor")
  func minimapViewportKeepsOnlyTheActiveDragCursor() throws {
    let source = try previewableSourceFile(named: "PolicyCanvasMinimapOverlay.swift")
    let pointerStyleCount = source.components(separatedBy: ".pointerStyle(.link)").count - 1

    #expect(source.contains("NSCursor.closedHand.push()"))
    #expect(source.contains("NSCursor.pop()"))
    #expect(!source.contains("NSCursor.pointingHand.set()"))
    #expect(pointerStyleCount == 1)
  }
}

private func previewableSourceFile(named relativePath: String) throws -> String {
  let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  let repoRoot =
    testsDirectory
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let fileURL =
    repoRoot
    .appendingPathComponent(
      "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views/PolicyCanvas"
    )
    .appendingPathComponent(relativePath)
  return try String(contentsOf: fileURL, encoding: .utf8)
}

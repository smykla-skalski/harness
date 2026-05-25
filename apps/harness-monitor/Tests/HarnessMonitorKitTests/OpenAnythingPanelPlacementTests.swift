import CoreGraphics
import HarnessMonitorKit
import Testing

@Suite("OpenAnything panel placement")
struct OpenAnythingPanelPlacementTests {
  private let panel = CGSize(width: 720, height: 400)
  private let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
  private let secondary = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

  @Test("Centers the panel on both axes within the visible frame")
  func centersWithinVisibleFrame() {
    let origin = OpenAnythingPanelPlacement.centeredOrigin(panelSize: panel, in: primary)
    #expect(origin.x == 600)
    #expect(origin.y == 340)
  }

  @Test("Centering respects a non-zero frame origin (second display)")
  func centersWithinOffsetFrame() {
    let origin = OpenAnythingPanelPlacement.centeredOrigin(panelSize: panel, in: secondary)
    #expect(origin.x == 2520)
    #expect(origin.y == 340)
  }

  @Test("Clamping leaves an already-onscreen origin untouched")
  func clampLeavesOnscreenOriginUntouched() {
    let origin = CGPoint(x: 600, y: 340)
    let clamped = OpenAnythingPanelPlacement.clampedOrigin(
      origin, panelSize: panel, visibleFrame: primary
    )
    #expect(clamped == origin)
  }

  @Test("Clamping pulls an origin past the trailing edge back inside the inset")
  func clampPullsTrailingEdgeInside() {
    let clamped = OpenAnythingPanelPlacement.clampedOrigin(
      CGPoint(x: 1500, y: 340), panelSize: panel, visibleFrame: primary
    )
    // maxX - width - inset = 1920 - 720 - 12 = 1188
    #expect(clamped.x == 1188)
    #expect(clamped.y == 340)
  }

  @Test("Clamping pulls an origin below the bottom edge up to the inset")
  func clampPullsBottomEdgeInside() {
    let clamped = OpenAnythingPanelPlacement.clampedOrigin(
      CGPoint(x: 600, y: -50), panelSize: panel, visibleFrame: primary
    )
    #expect(clamped.x == 600)
    #expect(clamped.y == 12)
  }

  @Test("A panel wider than the frame centers on that axis instead of clamping negative")
  func clampCentersOversizedPanel() {
    let wide = CGSize(width: 2000, height: 400)
    let clamped = OpenAnythingPanelPlacement.clampedOrigin(
      CGPoint(x: 9999, y: 340), panelSize: wide, visibleFrame: primary
    )
    // (1920 - 2000) / 2 = -40
    #expect(clamped.x == -40)
  }

  @Test("No saved origin centers in the default frame")
  func resolvedWithoutSavedCenters() {
    let origin = OpenAnythingPanelPlacement.resolvedOrigin(
      savedOrigin: nil,
      panelSize: panel,
      visibleFrames: [primary],
      defaultVisibleFrame: primary
    )
    #expect(origin == CGPoint(x: 600, y: 340))
  }

  @Test("A fully-onscreen saved origin is restored unchanged")
  func resolvedRestoresOnscreenOrigin() {
    let saved = CGPoint(x: 200, y: 150)
    let origin = OpenAnythingPanelPlacement.resolvedOrigin(
      savedOrigin: saved,
      panelSize: panel,
      visibleFrames: [primary],
      defaultVisibleFrame: primary
    )
    #expect(origin == saved)
  }

  @Test("A partially-offscreen saved origin is clamped onto its screen")
  func resolvedClampsPartiallyOffscreenOrigin() {
    // Origin pushed right so the panel hangs off the trailing edge.
    let origin = OpenAnythingPanelPlacement.resolvedOrigin(
      savedOrigin: CGPoint(x: 1800, y: 150),
      panelSize: panel,
      visibleFrames: [primary],
      defaultVisibleFrame: primary
    )
    #expect(origin.x == 1188)
    #expect(origin.y == 150)
  }

  @Test("A saved origin on a now-absent display falls back to centering")
  func resolvedFallsBackWhenOriginFullyOffscreen() {
    // Saved on a second monitor that is no longer connected.
    let origin = OpenAnythingPanelPlacement.resolvedOrigin(
      savedOrigin: CGPoint(x: 3000, y: 150),
      panelSize: panel,
      visibleFrames: [primary],
      defaultVisibleFrame: primary
    )
    #expect(origin == CGPoint(x: 600, y: 340))
  }

  @Test("A saved origin on the second display is clamped against that display")
  func resolvedKeepsOriginOnSecondaryDisplay() {
    let saved = CGPoint(x: 2200, y: 150)
    let origin = OpenAnythingPanelPlacement.resolvedOrigin(
      savedOrigin: saved,
      panelSize: panel,
      visibleFrames: [primary, secondary],
      defaultVisibleFrame: primary
    )
    // Fully inside the secondary frame, so it is restored unchanged rather
    // than recentered onto the primary default frame.
    #expect(origin == saved)
  }
}

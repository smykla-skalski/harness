import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas wheel scroll smoothing")
struct PolicyCanvasWheelScrollSmoothingTests {
  @Test("wheel smoothing interpolates toward the target with an ease-out curve")
  func interpolatesTowardTargetWithEaseOutCurve() {
    let animation = PolicyCanvasWheelScrollAnimation(
      startOrigin: CGPoint(x: 10, y: 20),
      targetOrigin: CGPoint(x: 110, y: 220),
      startTime: 100,
      duration: 0.2
    )

    #expect(animation.origin(at: 100) == CGPoint(x: 10, y: 20))
    let midpoint = animation.origin(at: 100.1)
    #expect(midpoint.x > 60)
    #expect(midpoint.y > 120)
    #expect(animation.origin(at: 100.2) == CGPoint(x: 110, y: 220))
    #expect(animation.isComplete(at: 100.2))
  }

  @Test("wheel smoothing ignores subpixel targets")
  func ignoresSubpixelTargets() {
    #expect(
      !PolicyCanvasWheelScrollSmoothing.shouldAnimate(
        from: CGPoint(x: 10, y: 10),
        to: CGPoint(x: 10.25, y: 10.25)
      )
    )
    #expect(
      PolicyCanvasWheelScrollSmoothing.shouldAnimate(
        from: CGPoint(x: 10, y: 10),
        to: CGPoint(x: 10.75, y: 10)
      )
    )
  }

  @Test("native scroll view smooths only coarse wheel input")
  func nativeScrollViewSmoothsOnlyCoarseWheelInput() throws {
    let nativeScrollViewSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNativeScrollView.swift"
    )
    let nativeScrollViewSmoothingSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNativeScrollView+WheelSmoothing.swift"
    )
    let smoothingSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWheelScrollSmoothing.swift"
    )

    #expect(
      nativeScrollViewSmoothingSource.contains(
        "PolicyCanvasWheelScrollSmoothing.shouldSmooth(event: event)"
      )
    )
    #expect(nativeScrollViewSource.contains("isSamplingWheelScrollTarget"))
    #expect(nativeScrollViewSmoothingSource.contains("super.scrollWheel(with: event)"))
    #expect(
      nativeScrollViewSmoothingSource.contains("RunLoop.main.add(timer, forMode: .common)")
    )
    #expect(smoothingSource.contains("event.hasPreciseScrollingDeltas == false"))
    #expect(smoothingSource.contains("event.phase.isEmpty"))
    #expect(smoothingSource.contains("event.momentumPhase.isEmpty"))
    #expect(smoothingSource.contains("!event.modifierFlags.contains(.command)"))
  }

  private func previewableSourceFile(named path: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(path)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}

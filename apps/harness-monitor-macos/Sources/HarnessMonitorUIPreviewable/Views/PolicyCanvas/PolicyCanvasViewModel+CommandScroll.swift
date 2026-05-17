import SwiftUI

extension PolicyCanvasViewModel {
  /// Cmd-modified scroll-wheel zoom step. Mouse-wheel users hit this whenever
  /// they hold Cmd and scroll; trackpad users keep using `MagnifyGesture`. The
  /// curve is intentionally smaller-per-tick than chrome buttons (which step
  /// by 0.1) because scroll events arrive at the wheel's native cadence and a
  /// 0.1 step per tick would slingshot to the clamps in a single flick.
  ///
  /// Returns true iff the zoom value actually changed; the view reads the
  /// return value to decide whether to recompute scroll offset and apply the
  /// no-feedback restore.
  @discardableResult
  func zoomByCommandScroll(deltaY: CGFloat) -> Bool {
    guard abs(deltaY) >= 0.1 else {
      return false
    }
    let oldZoom = zoom
    let boundedDelta = min(80, max(-80, deltaY))
    let zoomStep = 1 + (boundedDelta * 0.003)
    setZoom(zoom * max(0.76, min(1.24, zoomStep)))
    return zoom != oldZoom
  }

  /// Compute the scroll offset that keeps `canvasPoint` (in unscaled canvas
  /// coordinates) under `viewportPoint` (in viewport coordinates) after the
  /// zoom changed. The new offset is clamped to the scaled content extent so
  /// callers don't push the scroll past the content bounds.
  func viewportScrollPoint(
    keepingCanvasPoint canvasPoint: CGPoint,
    atViewportPoint viewportPoint: CGPoint,
    viewportSize: CGSize,
    scaledCanvasOffset: CGPoint = .zero,
    contentSize: CGSize? = nil
  ) -> CGPoint {
    let contentSize = contentSize ?? scaledCanvasContentSize(for: viewportSize)
    return CGPoint(
      x: clampedScrollOffset(
        scaledCanvasOffset.x + (canvasPoint.x * zoom) - viewportPoint.x,
        contentLength: contentSize.width,
        viewportLength: viewportSize.width
      ),
      y: clampedScrollOffset(
        scaledCanvasOffset.y + (canvasPoint.y * zoom) - viewportPoint.y,
        contentLength: contentSize.height,
        viewportLength: viewportSize.height
      )
    )
  }

  private func scaledCanvasContentSize(for viewportSize: CGSize) -> CGSize {
    CGSize(
      width: max(viewportSize.width, canvasContentSize.width * zoom),
      height: max(viewportSize.height, canvasContentSize.height * zoom)
    )
  }

  private func clampedScrollOffset(
    _ proposedOffset: CGFloat,
    contentLength: CGFloat,
    viewportLength: CGFloat
  ) -> CGFloat {
    min(max(0, proposedOffset), max(0, contentLength - viewportLength))
  }
}

/// Pure delta helper consumed by `PolicyCanvasViewport.handleScrollOffsetChange`.
/// Free function (not on the view model) so it stays trivially testable without
/// constructing a `PolicyCanvasViewModel`. Returns the dominant-axis delta or
/// nil when Cmd was not held or the scroll did not move.
func policyCanvasCommandScrollDeltaY(
  isCommandModified: Bool,
  oldOffset: CGPoint,
  newOffset: CGPoint
) -> CGFloat? {
  guard isCommandModified else {
    return nil
  }
  let deltaY = oldOffset.y - newOffset.y
  if abs(deltaY) >= 0.1 {
    return deltaY
  }
  let deltaX = oldOffset.x - newOffset.x
  if abs(deltaX) >= 0.1 {
    return deltaX
  }
  return nil
}

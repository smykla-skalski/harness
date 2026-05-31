import AppKit
import SwiftUI

extension PolicyCanvasViewModel {
  /// Command-modified scroll-wheel zoom step. Mouse-wheel users hit this
  /// whenever they hold Command and scroll; the native AppKit scroll host uses
  /// the same curve for Command+trackpad scrolling. The curve is intentionally
  /// smaller-per-tick than chrome buttons (which step
  /// by 0.1) because scroll events arrive at the wheel's native cadence and a
  /// 0.1 step per tick would slingshot to the clamps in a single flick.
  ///
  /// Returns true iff the zoom value actually changed; the view reads the
  /// return value to decide whether to recompute scroll offset and apply the
  /// no-feedback restore.
  @discardableResult
  func zoomByCommandScroll(deltaY: CGFloat) -> Bool {
    guard
      let targetZoom = policyCanvasCommandScrollTargetZoom(
        currentZoom: zoom,
        deltaY: deltaY
      )
    else {
      return false
    }
    setZoom(targetZoom)
    return true
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
    contentSize: CGSize? = nil,
    zoomOverride: CGFloat? = nil
  ) -> CGPoint {
    let resolvedZoom = zoomOverride ?? zoom
    let contentSize = contentSize ?? scaledCanvasContentSize(for: viewportSize, zoom: resolvedZoom)
    return CGPoint(
      x: clampedScrollOffset(
        scaledCanvasOffset.x + (canvasPoint.x * resolvedZoom) - viewportPoint.x,
        contentLength: contentSize.width,
        viewportLength: viewportSize.width
      ),
      y: clampedScrollOffset(
        scaledCanvasOffset.y + (canvasPoint.y * resolvedZoom) - viewportPoint.y,
        contentLength: contentSize.height,
        viewportLength: viewportSize.height
      )
    )
  }

  private func scaledCanvasContentSize(for viewportSize: CGSize, zoom: CGFloat) -> CGSize {
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

@MainActor
func policyCanvasCommandScrollTargetZoom(
  currentZoom: CGFloat,
  deltaY: CGFloat
) -> CGFloat? {
  guard abs(deltaY) >= 0.1 else {
    return nil
  }
  let boundedDelta = min(80, max(-80, deltaY))
  let zoomStep = 1 + (boundedDelta * 0.003)
  let candidateZoom = currentZoom * max(0.76, min(1.24, zoomStep))
  let targetZoom = PolicyCanvasViewModel.sanitizedZoom(
    candidateZoom,
    fallback: currentZoom
  )
  return targetZoom == currentZoom ? nil : targetZoom
}

/// Pure delta helper consumed by the canvas' native scroll-wheel interception
/// path. Free function (not on the view model) so it stays trivially testable
/// without constructing a `PolicyCanvasViewModel`. Returns the dominant-axis
/// delta or nil when Command was not held or the wheel/trackpad did not move.
func policyCanvasCommandScrollDeltaY(
  isCommandModified: Bool,
  verticalDelta: CGFloat,
  horizontalDelta: CGFloat
) -> CGFloat? {
  guard isCommandModified else {
    return nil
  }
  if abs(verticalDelta) >= 0.1 {
    return verticalDelta
  }
  if abs(horizontalDelta) >= 0.1 {
    return horizontalDelta
  }
  return nil
}

func policyCanvasCommandScrollDeltaY(
  isCommandModified: Bool,
  oldOffset: CGPoint,
  newOffset: CGPoint
) -> CGFloat? {
  policyCanvasCommandScrollDeltaY(
    isCommandModified: isCommandModified,
    verticalDelta: oldOffset.y - newOffset.y,
    horizontalDelta: oldOffset.x - newOffset.x
  )
}

func policyCanvasCommandScrollDeltaY(event: NSEvent) -> CGFloat? {
  guard event.momentumPhase.isEmpty else {
    return nil
  }
  let verticalDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
  let horizontalDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX
  return policyCanvasCommandScrollDeltaY(
    isCommandModified: event.modifierFlags.contains(.command),
    verticalDelta: verticalDelta,
    horizontalDelta: horizontalDelta
  )
}

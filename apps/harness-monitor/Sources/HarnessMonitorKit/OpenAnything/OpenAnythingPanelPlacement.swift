import CoreGraphics

/// Pure geometry for placing the Open Anything floating panel. The panel opens
/// centered on the active screen by default; once the user drags it the saved
/// origin is restored on the next show, clamped back onto whichever screen now
/// best contains it so an unplugged display can never strand the palette
/// offscreen.
///
/// Kept free of AppKit so the placement math is unit-testable without a live
/// `NSScreen`/`NSWindow`. The controller supplies real `visibleFrame`s.
public enum OpenAnythingPanelPlacement {
  /// Margin kept between the panel and the edge of the visible frame when a
  /// restored origin has to be pulled back onscreen.
  public static let screenEdgeInset: CGFloat = 12

  /// Origin that centers a `panelSize` panel inside `visibleFrame` on both axes.
  public static func centeredOrigin(panelSize: CGSize, in visibleFrame: CGRect) -> CGPoint {
    CGPoint(
      x: visibleFrame.midX - panelSize.width / 2,
      y: visibleFrame.midY - panelSize.height / 2
    )
  }

  /// Clamp `origin` so a `panelSize` panel stays inside `visibleFrame` minus
  /// `inset`. When the panel is larger than the frame on an axis it is centered
  /// on that axis instead of clamped to a negative span.
  public static func clampedOrigin(
    _ origin: CGPoint,
    panelSize: CGSize,
    visibleFrame: CGRect,
    inset: CGFloat = screenEdgeInset
  ) -> CGPoint {
    CGPoint(
      x: clampedAxis(
        origin.x,
        frameMin: visibleFrame.minX,
        frameSpan: visibleFrame.width,
        panelSpan: panelSize.width,
        inset: inset
      ),
      y: clampedAxis(
        origin.y,
        frameMin: visibleFrame.minY,
        frameSpan: visibleFrame.height,
        panelSpan: panelSize.height,
        inset: inset
      )
    )
  }

  /// Resolve where to place the panel on show. Restores `savedOrigin` (clamped
  /// onto whichever frame in `visibleFrames` it best overlaps) when one exists
  /// and still lands on a screen; otherwise centers in `defaultVisibleFrame`.
  public static func resolvedOrigin(
    savedOrigin: CGPoint?,
    panelSize: CGSize,
    visibleFrames: [CGRect],
    defaultVisibleFrame: CGRect,
    inset: CGFloat = screenEdgeInset
  ) -> CGPoint {
    guard let saved = savedOrigin else {
      return centeredOrigin(panelSize: panelSize, in: defaultVisibleFrame)
    }
    let panelRect = CGRect(origin: saved, size: panelSize)
    let best = visibleFrames
      .map { frame -> (frame: CGRect, area: CGFloat) in
        let overlap = frame.intersection(panelRect)
        return (frame, overlap.isNull ? 0 : overlap.width * overlap.height)
      }
      .max { $0.area < $1.area }
    guard let best, best.area > 0 else {
      return centeredOrigin(panelSize: panelSize, in: defaultVisibleFrame)
    }
    return clampedOrigin(saved, panelSize: panelSize, visibleFrame: best.frame, inset: inset)
  }

  /// Clamp a single axis into `[frameMin + inset, frameMax - panelSpan - inset]`,
  /// centering when the panel is larger than the available span.
  private static func clampedAxis(
    _ value: CGFloat,
    frameMin: CGFloat,
    frameSpan: CGFloat,
    panelSpan: CGFloat,
    inset: CGFloat
  ) -> CGFloat {
    let lower = frameMin + inset
    let upper = frameMin + frameSpan - panelSpan - inset
    guard lower <= upper else {
      return frameMin + (frameSpan - panelSpan) / 2
    }
    return Swift.min(Swift.max(value, lower), upper)
  }
}

import AppKit

final class PolicyCanvasCenteringClipView: NSClipView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    drawsBackground = false
    backgroundColor = .clear
    wantsLayer = true
    layer?.masksToBounds = true
    disableScrollCopyReuse()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func disableScrollCopyReuse() {
    let setter = NSSelectorFromString("setCopiesOnScroll:")
    guard responds(to: setter) else {
      return
    }
    // AppKit's legacy scroll-copy path reuses old backing pixels while only
    // redrawing the newly exposed strip. The canvas relayouts and magnifies
    // inside the clip view, so stale copied strips are worse than a redraw.
    setValue(false, forKey: "copiesOnScroll")
  }

  override func setFrameSize(_ newSize: NSSize) {
    let previousFrameSize = frame.size
    let preservedOrigin: CGPoint?
    let preservedCenter: CGPoint?
    if bounds.width > 1, bounds.height > 1, documentView != nil {
      preservedOrigin = bounds.origin
      preservedCenter = CGPoint(x: bounds.midX, y: bounds.midY)
    } else {
      preservedOrigin = nil
      preservedCenter = nil
    }

    let scrollView = enclosingScrollView as? PolicyCanvasNativeScrollView
    scrollView?.beginViewportFrameResizePreservation()
    defer {
      scrollView?.endViewportFrameResizePreservation()
    }

    super.setFrameSize(newSize)

    // Proportional-scale viewports (the minimap preview) zoom the content around
    // the preserved center and own the post-resize scroll themselves.
    if let preservedCenter,
      scrollView?.applyViewportFrameResizeZoomIfNeeded(
        from: previousFrameSize,
        to: newSize,
        centeredAt: preservedCenter
      ) == true
    {
      return
    }

    // Default canvas: pin the visible top-left, not the center. The pane is
    // anchored at its top-left and only changes size from the bottom-right edge
    // (a side inspector opening, a window resize), so preserving the center slid
    // the whole graph sideways every time the pane width changed. Holding the
    // origin keeps the graph visually still; constrainBoundsRect still clamps it
    // back inside the document when the viewport overhangs the content.
    guard let preservedOrigin else {
      return
    }
    guard
      abs(bounds.origin.x - preservedOrigin.x) > 0.5
        || abs(bounds.origin.y - preservedOrigin.y) > 0.5
    else {
      return
    }
    scroll(to: preservedOrigin)
  }

  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var constrained = super.constrainBoundsRect(proposedBounds)
    guard let documentView else {
      return constrained
    }
    if documentView.frame.width < constrained.width {
      constrained.origin.x = -((constrained.width - documentView.frame.width) / 2)
    }
    if documentView.frame.height < constrained.height {
      constrained.origin.y = -((constrained.height - documentView.frame.height) / 2)
    }
    return constrained
  }
}

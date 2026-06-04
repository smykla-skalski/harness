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
    let preservedCenter: CGPoint?
    if bounds.width > 1, bounds.height > 1, documentView != nil {
      preservedCenter = CGPoint(x: bounds.midX, y: bounds.midY)
    } else {
      preservedCenter = nil
    }

    let scrollView = enclosingScrollView as? PolicyCanvasNativeScrollView
    scrollView?.beginViewportFrameResizePreservation()
    defer {
      scrollView?.endViewportFrameResizePreservation()
    }

    super.setFrameSize(newSize)

    guard let preservedCenter else {
      return
    }

    let targetOrigin = CGPoint(
      x: preservedCenter.x - (bounds.width / 2),
      y: preservedCenter.y - (bounds.height / 2)
    )
    guard
      abs(bounds.origin.x - targetOrigin.x) > 0.5
        || abs(bounds.origin.y - targetOrigin.y) > 0.5
    else {
      return
    }
    scroll(to: targetOrigin)
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

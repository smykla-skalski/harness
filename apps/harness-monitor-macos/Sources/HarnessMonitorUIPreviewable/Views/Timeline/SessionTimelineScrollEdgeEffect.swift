import AppKit

private enum SessionTimelineScrollEdge {
  case top
  case bottom
}

final class SessionTimelineTableScrollView: NSScrollView {
  private let topEdgeEffectView = SessionTimelineScrollEdgeEffectView(edge: .top)
  private let bottomEdgeEffectView = SessionTimelineScrollEdgeEffectView(edge: .bottom)
  private var topScrollEdgeHeight: CGFloat = 0
  private var bottomScrollEdgeHeight: CGFloat = 0
  private var installedEdgeEffectViews = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func installScrollEdgeEffectViews() {
    guard !installedEdgeEffectViews else {
      return
    }
    installedEdgeEffectViews = true
    addSubview(topEdgeEffectView, positioned: .above, relativeTo: contentView)
    addSubview(bottomEdgeEffectView, positioned: .above, relativeTo: contentView)
    topEdgeEffectView.isHidden = true
    bottomEdgeEffectView.isHidden = true
    layoutEdgeEffectViews()
  }

  func updateScrollEdgeEffectHeights(top: CGFloat, bottom: CGFloat) {
    let resolvedTop = max(top, 0)
    let resolvedBottom = max(bottom, 0)
    guard
      abs(topScrollEdgeHeight - resolvedTop) > 0.5
        || abs(bottomScrollEdgeHeight - resolvedBottom) > 0.5
    else {
      return
    }
    topScrollEdgeHeight = resolvedTop
    bottomScrollEdgeHeight = resolvedBottom
    layoutEdgeEffectViews()
  }

  override func tile() {
    super.tile()
    layoutEdgeEffectViews()
  }

  override func layout() {
    super.layout()
    layoutEdgeEffectViews()
  }

  private func layoutEdgeEffectViews() {
    guard installedEdgeEffectViews else {
      return
    }
    let clipFrame = contentView.frame
    guard clipFrame.width > 0, clipFrame.height > 0 else {
      topEdgeEffectView.isHidden = true
      bottomEdgeEffectView.isHidden = true
      return
    }

    topEdgeEffectView.isHidden = topScrollEdgeHeight <= 0
    bottomEdgeEffectView.isHidden = bottomScrollEdgeHeight <= 0

    let maximumEdgeHeight = clipFrame.height * 0.5

    if topScrollEdgeHeight > 0 {
      let resolvedHeight = min(topScrollEdgeHeight, maximumEdgeHeight)
      topEdgeEffectView.frame = NSRect(
        x: clipFrame.minX,
        y: clipFrame.maxY - resolvedHeight,
        width: clipFrame.width,
        height: resolvedHeight
      )
    }

    if bottomScrollEdgeHeight > 0 {
      let resolvedHeight = min(bottomScrollEdgeHeight, maximumEdgeHeight)
      bottomEdgeEffectView.frame = NSRect(
        x: clipFrame.minX,
        y: clipFrame.minY,
        width: clipFrame.width,
        height: resolvedHeight
      )
    }
  }
}

private final class SessionTimelineScrollEdgeEffectView: NSVisualEffectView {
  private let edge: SessionTimelineScrollEdge
  private var lastMaskSize: NSSize = .zero

  init(edge: SessionTimelineScrollEdge) {
    self.edge = edge
    super.init(frame: .zero)
    blendingMode = .withinWindow
    material = .headerView
    state = .active
    isEmphasized = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }

  override func layout() {
    super.layout()
    updateMaskIfNeeded()
  }

  private func updateMaskIfNeeded() {
    let maskSize = bounds.size
    guard maskSize.width > 1, maskSize.height > 1 else {
      lastMaskSize = .zero
      maskImage = nil
      return
    }
    guard lastMaskSize != maskSize else {
      return
    }
    lastMaskSize = maskSize
    maskImage = makeMaskImage(size: maskSize)
  }

  private func makeMaskImage(size: NSSize) -> NSImage {
    let gradient =
      switch edge {
      case .top:
        CGGradient(
          colorsSpace: CGColorSpaceCreateDeviceRGB(),
          colors: [
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
          ] as CFArray,
          locations: [0, 1]
        )
      case .bottom:
        CGGradient(
          colorsSpace: CGColorSpaceCreateDeviceRGB(),
          colors: [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.cgColor,
          ] as CFArray,
          locations: [0, 1]
        )
      }

    return NSImage(size: size, flipped: true) { rect in
      guard
        let gradient,
        let context = NSGraphicsContext.current?.cgContext
      else {
        return false
      }
      let start = CGPoint(x: rect.midX, y: 0)
      let end = CGPoint(x: rect.midX, y: rect.maxY)
      context.drawLinearGradient(gradient, start: start, end: end, options: [])
      return true
    }
  }
}

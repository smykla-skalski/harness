import AppKit
import SwiftUI

struct PolicyCanvasDottedGrid: NSViewRepresentable {
  let spacing: CGFloat

  func makeNSView(context: Context) -> PolicyCanvasDottedGridView {
    let view = PolicyCanvasDottedGridView()
    view.updateSpacing(spacing)
    return view
  }

  func updateNSView(_ nsView: PolicyCanvasDottedGridView, context: Context) {
    nsView.updateSpacing(spacing)
  }
}

@MainActor
final class PolicyCanvasDottedGridView: NSView {
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }

  private var spacing: CGFloat = 8

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateSpacing(_ newSpacing: CGFloat) {
    let clampedSpacing = max(8, newSpacing)
    guard abs(spacing - clampedSpacing) > .ulpOfOne else {
      return
    }
    spacing = clampedSpacing
    needsDisplay = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()

    guard let context = NSGraphicsContext.current?.cgContext else {
      return
    }
    context.setFillColor(NSColor.separatorColor.withAlphaComponent(0.35).cgColor)
    for point in policyCanvasVisibleGridPoints(in: dirtyRect, spacing: spacing) {
      context.fillEllipse(in: CGRect(x: point.x, y: point.y, width: 1, height: 1))
    }
  }
}

private func policyCanvasVisibleGridPoints(in rect: CGRect, spacing: CGFloat) -> [CGPoint] {
  guard rect.width > 0, rect.height > 0 else {
    return []
  }

  let clampedSpacing = max(8, spacing)
  let startX = floor(rect.minX / clampedSpacing) * clampedSpacing
  let endX = ceil(rect.maxX / clampedSpacing) * clampedSpacing
  let startY = floor(rect.minY / clampedSpacing) * clampedSpacing
  let endY = ceil(rect.maxY / clampedSpacing) * clampedSpacing

  let columnCount = Int(((endX - startX) / clampedSpacing).rounded(.down)) + 1
  let rowCount = Int(((endY - startY) / clampedSpacing).rounded(.down)) + 1
  var points: [CGPoint] = []
  points.reserveCapacity(max(0, columnCount) * max(0, rowCount))

  var x = startX
  while x <= endX + 0.5 {
    var y = startY
    while y <= endY + 0.5 {
      points.append(CGPoint(x: x, y: y))
      y += clampedSpacing
    }
    x += clampedSpacing
  }
  return points
}

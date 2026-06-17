import AppKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

private let policyCanvasDenseEdgeDirtyPadding: CGFloat = 18

struct PolicyCanvasDenseEdgeDrawingSurface: NSViewRepresentable {
  let items: [PolicyCanvasDenseEdgeDrawingItem]

  func makeNSView(context: Context) -> PolicyCanvasDenseEdgeDrawingView {
    PolicyCanvasDenseEdgeDrawingView()
  }

  func updateNSView(_ nsView: PolicyCanvasDenseEdgeDrawingView, context: Context) {
    nsView.items = items
  }
}

struct PolicyCanvasDenseEdgeDrawingItem: Equatable {
  let route: PolicyCanvasEdgeRoute
  let dirtyBounds: CGRect
  let labelGapFrames: [CGRect]
  let strokeColor: Color
  let arrowheadColor: Color
  let strokeWidth: CGFloat
  let dashPattern: [CGFloat]
  let isSelected: Bool
}

private struct PolicyCanvasDenseEdgeRenderedItem {
  let dirtyBounds: CGRect
  let paths: [NSBezierPath]
  let arrowheadPath: NSBezierPath?
  let strokeColor: Color
  let arrowheadColor: Color
  let strokeWidth: CGFloat
  let dashPattern: [CGFloat]
  let isSelected: Bool

  init(item: PolicyCanvasDenseEdgeDrawingItem) {
    dirtyBounds = item.dirtyBounds
    paths =
      policyCanvasVisibleEdgeSubroutes(
        points: item.route.points,
        gapFrames: item.labelGapFrames
      )
      .compactMap { policyCanvasAppKitEdgePath(points: $0) }
    arrowheadPath = policyCanvasDenseEdgeArrowheadPath(route: item.route)
    strokeColor = item.strokeColor
    arrowheadColor = item.arrowheadColor
    strokeWidth = item.strokeWidth
    dashPattern = item.dashPattern
    isSelected = item.isSelected
  }
}

@MainActor
final class PolicyCanvasDenseEdgeDrawingView: NSView {
  var items: [PolicyCanvasDenseEdgeDrawingItem] = [] {
    didSet {
      guard items != oldValue else {
        return
      }
      renderedItems = items.map(PolicyCanvasDenseEdgeRenderedItem.init(item:))
      needsDisplay = true
    }
  }

  private var renderedItems: [PolicyCanvasDenseEdgeRenderedItem] = []

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    policyCanvasApplyTransparentDrawingBacking(to: self)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      for item in renderedItems {
        guard item.dirtyBounds.intersects(dirtyRect) else {
          continue
        }
        draw(item)
      }
    }
  }

  private func draw(_ item: PolicyCanvasDenseEdgeRenderedItem) {
    for path in item.paths {
      if item.isSelected {
        policyCanvasStroke(
          path,
          color: PolicyCanvasVisualStyle.activeTint,
          alpha: 0.18,
          lineWidth: 5
        )
      }
      policyCanvasStroke(
        path,
        color: item.strokeColor,
        lineWidth: item.strokeWidth,
        dash: item.dashPattern
      )
    }

    if let arrowhead = item.arrowheadPath {
      policyCanvasFill(arrowhead, color: item.arrowheadColor)
    }
  }
}

private func policyCanvasDenseEdgeArrowheadPath(route: PolicyCanvasEdgeRoute) -> NSBezierPath? {
  let points = route.points
  guard points.count >= 2, let tip = points.last else {
    return nil
  }
  let previous = points[points.count - 2]
  let direction = (tip - previous).normalized
  guard direction.length > 0 else {
    return nil
  }
  let length: CGFloat = 12
  let halfWidth: CGFloat = 4.5
  let perpendicular = CGPoint(x: -direction.y, y: direction.x)
  let base = tip - direction * length
  let path = NSBezierPath()
  path.move(to: tip)
  path.line(to: base + perpendicular * halfWidth)
  path.line(to: base - perpendicular * halfWidth)
  path.close()
  return path
}

func policyCanvasDenseEdgeDirtyBounds(
  route: PolicyCanvasEdgeRoute,
  labelGapFrames: [CGRect],
  strokeWidth: CGFloat,
  isSelected: Bool
) -> CGRect {
  var bounds = policyCanvasRouteBounds(route).standardized
  for frame in labelGapFrames {
    bounds = bounds.union(frame)
  }
  let selectionHaloWidth: CGFloat = isSelected ? 5 : 0
  let padding =
    policyCanvasDenseEdgeDirtyPadding
    + max(strokeWidth, selectionHaloWidth)
    + 12
  return bounds.insetBy(dx: -padding, dy: -padding)
}

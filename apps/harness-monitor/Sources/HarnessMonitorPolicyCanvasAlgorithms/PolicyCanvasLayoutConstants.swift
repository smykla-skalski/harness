import CoreGraphics

enum PolicyCanvasLayout {
  static let gridSize: CGFloat = 20
  static let minimumZoom: CGFloat = 0.1
  static let maximumZoom: CGFloat = 1.4
  static let defaultZoom: CGFloat = 0.92
  static let nodeSize = CGSize(width: 168, height: 96)
  static let portDiameter: CGFloat = 18
  static let portHitTestExtension: CGFloat = 10
  static let groupCornerRadius: CGFloat = 8
  static let edgeLabelHeight: CGFloat = 28
  static let edgeLabelMaxWidth: CGFloat = 220
  static let edgeLabelLaneSpacing: CGFloat = 46
  static let edgeBusLaneSpacing: CGFloat = 38
  static let edgeLabelNodeClearance: CGFloat = 24
  static let edgeLabelHorizontalMargin: CGFloat = 14
  static let edgePortTurnMinimumLead: CGFloat = 36
  static let defaultEdgeLineSpacing: CGFloat = nodeSize.height / 5
  static let initialContentOrigin = CGPoint(x: 520, y: 480)
  static let initialViewportInset: CGFloat = 220
  static let initialViewportTopBias: CGFloat = 64
  static let groupHorizontalPadding: CGFloat = 44
  static let groupVerticalPadding: CGFloat = 52
  static let minimumGroupSize = CGSize(width: 220, height: 180)
  static let minimumCanvasSize = CGSize(width: 3_800, height: 3_000)
  static let canvasTrailingPadding: CGFloat = 1_200
  static let canvasBottomPadding: CGFloat = 1_200
  /// First center used when the user clicks a palette button. Subsequent
  /// clicks step away from this anchor by `paletteDropStep` so identical
  /// clicks don't pile on top of each other.
  static let initialPaletteDropAnchor = CGPoint(x: 640, y: 620)
  /// Per-click advance offset for palette button drops. 40pt = 2x grid step
  /// so the next drop lands cleanly on the grid and stays clear of the prior
  /// node frame.
  static let paletteDropStep: CGFloat = 40

  static func portY(index: Int, count: Int) -> CGFloat {
    guard count > 1 else {
      return nodeSize.height / 2
    }
    let step = min(CGFloat(24), nodeSize.height / CGFloat(count + 1))
    let top = (nodeSize.height - (step * CGFloat(count - 1))) / 2
    return top + (CGFloat(index) * step)
  }

  static func portX(index: Int, count: Int) -> CGFloat {
    guard count > 1 else {
      return nodeSize.width / 2
    }
    let step = min(CGFloat(32), nodeSize.width / CGFloat(count + 1))
    let leading = (nodeSize.width - (step * CGFloat(count - 1))) / 2
    return leading + (CGFloat(index) * step)
  }
}

// Quantizes a coordinate to the layout grid so fanout sort keys don't flip
// between adjacent integer buckets when a port anchor drags sub-pixel.
// Sub-pixel jitter previously toggled the rounded int (e.g. 100.4 -> 100,
// 100.6 -> 101) and reordered fanout mid-drag.
func policyCanvasFanoutBucketCoordinate(
  _ value: CGFloat,
  quantum: CGFloat = PolicyCanvasLayout.gridSize
) -> Int {
  let step = max(quantum, 1)
  return Int((value / step).rounded()) * Int(step)
}

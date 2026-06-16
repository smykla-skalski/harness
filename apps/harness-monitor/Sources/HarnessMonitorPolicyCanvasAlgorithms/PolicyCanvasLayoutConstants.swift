import CoreGraphics

public enum PolicyCanvasLayout {
  public static let gridSize: CGFloat = 20
  public static let minimumZoom: CGFloat = 0.1
  public static let maximumZoom: CGFloat = 2.0
  public static let defaultZoom: CGFloat = 0.92
  public static let nodeSize = CGSize(width: 168, height: 160)
  public static let portDiameter: CGFloat = 18
  public static let portHitTestExtension: CGFloat = 10
  public static let portMarkerInset: CGFloat = portDiameter / 2 + 2
  public static let verticalPortMarkerSpacing: CGFloat = portDiameter * 1.5
  public static let groupCornerRadius: CGFloat = 8
  public static let edgeLabelHeight: CGFloat = 28
  public static let edgeLabelMaxWidth: CGFloat = 220
  public static let edgeLabelLaneSpacing: CGFloat = 46
  public static let edgeBusLaneSpacing: CGFloat = 38
  public static let edgeLabelNodeClearance: CGFloat = 24
  public static let edgeLabelHorizontalMargin: CGFloat = 14
  public static let edgePortTurnMinimumLead: CGFloat = 36
  public static let defaultEdgeLineSpacing: CGFloat = 22.4
  public static let initialContentOrigin = CGPoint(x: 520, y: 480)
  public static let initialViewportInset: CGFloat = 220
  public static let initialViewportTopBias: CGFloat = 64
  public static let groupHorizontalPadding: CGFloat = 44
  public static let groupVerticalPadding: CGFloat = 52
  public static let minimumGroupSize = CGSize(width: 220, height: 180)
  public static let minimumCanvasSize = CGSize(width: 3_800, height: 3_000)
  public static let canvasTrailingPadding: CGFloat = 1_200
  public static let canvasBottomPadding: CGFloat = 1_200
  /// First center used when the user clicks a palette button. Subsequent
  /// clicks step away from this anchor by `paletteDropStep` so identical
  /// clicks don't pile on top of each other.
  public static let initialPaletteDropAnchor = CGPoint(x: 640, y: 620)
  /// Per-click advance offset for palette button drops. 40pt = 2x grid step
  /// so the next drop lands cleanly on the grid and stays clear of the prior
  /// node frame.
  public static let paletteDropStep: CGFloat = 40

  public static func portY(index: Int, count: Int) -> CGFloat {
    guard count > 1 else {
      return nodeSize.height / 2
    }
    let available = max(0, nodeSize.height - (portMarkerInset * 2))
    let step = min(verticalPortMarkerSpacing, available / CGFloat(count - 1))
    let span = step * CGFloat(count - 1)
    let top = min(
      max((nodeSize.height - span) / 2, portMarkerInset),
      nodeSize.height - portMarkerInset - span
    )
    return top + (CGFloat(index) * step)
  }

  public static func portX(index: Int, count: Int) -> CGFloat {
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
public func policyCanvasFanoutBucketCoordinate(
  _ value: CGFloat,
  quantum: CGFloat = PolicyCanvasLayout.gridSize
) -> Int {
  let step = max(quantum, 1)
  return Int((value / step).rounded()) * Int(step)
}

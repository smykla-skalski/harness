import CoreGraphics

extension PolicyCanvasVisibilityRouter {
  func visibilityGridAxes(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext,
    prepared: [CGRect],
    includeAllCorridorBounds: Bool = false
  ) -> (xs: [CGFloat], ys: [CGFloat]) {
    let corridorObstacles =
      includeAllCorridorBounds
      ? prepared
      : prepared.filter {
        max($0.width, $0.height) >= 220
      }
    let corridorStep = max(
      PolicyCanvasLayout.edgePortTurnMinimumLead,
      context.lineSpacing * 2
    )
    return (
      xs: Self.sortedAxisCoordinates(
        anchor1: source.x,
        anchor2: target.x,
        laneOffset: laneOffsetX(lane: context.lane, spacing: context.lineSpacing),
        bounds: prepared.map { ($0.minX, $0.maxX) },
        corridorBounds: corridorObstacles.map { ($0.minX, $0.maxX) },
        corridorStep: corridorStep,
        preferredCoordinates: context.corridorHint?.verticalLaneX.map { [$0] } ?? []
      ),
      ys: Self.sortedAxisCoordinates(
        anchor1: source.y,
        anchor2: target.y,
        laneOffset: laneOffsetY(lane: context.lane, spacing: context.lineSpacing),
        bounds: prepared.map { ($0.minY, $0.maxY) },
        corridorBounds: corridorObstacles.map { ($0.minY, $0.maxY) },
        corridorStep: corridorStep,
        preferredCoordinates: context.corridorHint.map { [$0.horizontalLaneY] } ?? []
      )
    )
  }

  /// Snap a coordinate to a 0.001pt grid before Set insertion. Sub-pt
  /// divergence from accumulated float math is below visual perception and
  /// well above 1-ULP error; bit-different computations that should produce
  /// the same logical value collapse to one grid line instead of doubling
  /// the A* search space.
  static func quantizedCoordinate(_ value: CGFloat) -> CGFloat {
    (value * 1_000).rounded() / 1_000
  }

  static func sortedAxisCoordinates(
    anchor1: CGFloat,
    anchor2: CGFloat,
    laneOffset: CGFloat,
    bounds: [(CGFloat, CGFloat)],
    corridorBounds: [(CGFloat, CGFloat)] = [],
    corridorStep: CGFloat,
    preferredCoordinates: [CGFloat] = []
  ) -> [CGFloat] {
    var values: Set<CGFloat> = [quantizedCoordinate(anchor1), quantizedCoordinate(anchor2)]
    let mid = (anchor1 + anchor2) / 2 + laneOffset
    values.insert(quantizedCoordinate(mid))
    for coordinate in preferredCoordinates {
      values.insert(quantizedCoordinate(coordinate))
    }
    for bound in corridorBounds {
      values.insert(quantizedCoordinate(bound.0 - corridorStep))
      values.insert(quantizedCoordinate(bound.1 + corridorStep))
    }
    for bound in bounds {
      values.insert(quantizedCoordinate(bound.0))
      values.insert(quantizedCoordinate(bound.1))
    }
    return values.sorted()
  }

  func laneOffsetX(lane: Int, spacing: CGFloat) -> CGFloat {
    CGFloat(((lane % 12) - 6)) * spacing
  }

  func laneOffsetY(lane: Int, spacing: CGFloat) -> CGFloat {
    CGFloat(((lane / 12) - 6)) * spacing
  }
}

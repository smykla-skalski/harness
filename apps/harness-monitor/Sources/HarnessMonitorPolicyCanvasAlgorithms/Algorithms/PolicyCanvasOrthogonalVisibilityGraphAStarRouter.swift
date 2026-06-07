import CoreGraphics

struct PolicyCanvasOrthogonalVisibilityGraphAStarRouter: PolicyCanvasEdgeRouter {
  func route(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    let obstacles = preparedObstacles(source: source, target: target, raw: context.obstacles)
    let axes = gridAxes(source: source, target: target, obstacles: obstacles)
    guard
      let sourceX = axes.xs.firstIndex(
        of: PolicyCanvasVisibilityRouter.quantizedCoordinate(source.x)
      ),
      let sourceY = axes.ys.firstIndex(
        of: PolicyCanvasVisibilityRouter.quantizedCoordinate(source.y)
      ),
      let targetX = axes.xs.firstIndex(
        of: PolicyCanvasVisibilityRouter.quantizedCoordinate(target.x)
      ),
      let targetY = axes.ys.firstIndex(
        of: PolicyCanvasVisibilityRouter.quantizedCoordinate(target.y)
      ),
      let result = PolicyCanvasVisibilityAStar.run(
        gridXs: axes.xs,
        gridYs: axes.ys,
        sourceIndex: PolicyCanvasGridIndex(x: sourceX, y: sourceY),
        targetIndex: PolicyCanvasGridIndex(x: targetX, y: targetY),
        obstacles: obstacles
      )
    else {
      return PolicyCanvasHandCodedOrthogonalRouter().route(
        source: source,
        target: target,
        context: context
      )
    }
    let points = PolicyCanvasVisibilityRouter.compressCollinear(result.points)
    return PolicyCanvasEdgeRoute(
      points: points,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: points)
    )
  }

  private func preparedObstacles(
    source: CGPoint,
    target: CGPoint,
    raw: [CGRect]
  ) -> [CGRect] {
    raw.filter { obstacle in
      let endpointProbe = obstacle.insetBy(
        dx: -PolicyCanvasVisibilityRouter.endpointDropProbe,
        dy: -PolicyCanvasVisibilityRouter.endpointDropProbe
      )
      return !endpointProbe.contains(source) && !endpointProbe.contains(target)
    }
  }

  private func gridAxes(
    source: CGPoint,
    target: CGPoint,
    obstacles: [CGRect]
  ) -> (xs: [CGFloat], ys: [CGFloat]) {
    let clearance = PolicyCanvasLayout.edgePortTurnMinimumLead
    var xs = [source.x, target.x, (source.x + target.x) / 2]
    var ys = [source.y, target.y, (source.y + target.y) / 2]
    for obstacle in obstacles {
      xs.append(contentsOf: [
        obstacle.minX - clearance,
        obstacle.minX,
        obstacle.maxX,
        obstacle.maxX + clearance,
      ])
      ys.append(contentsOf: [
        obstacle.minY - clearance,
        obstacle.minY,
        obstacle.maxY,
        obstacle.maxY + clearance,
      ])
    }
    return (sortedUnique(xs), sortedUnique(ys))
  }

  private func sortedUnique(_ values: [CGFloat]) -> [CGFloat] {
    Array(Set(values.map(PolicyCanvasVisibilityRouter.quantizedCoordinate))).sorted()
  }
}

import CoreGraphics
import Foundation

/// A* pathfinder over the sparse orthogonal visibility grid built by
/// `PolicyCanvasVisibilityRouter`. State is (gridIndex, lastDirection) so the
/// bend-penalty applies on real axis transitions instead of every revisit. The
/// engine moves to the nearest unblocked grid neighbor on each axis from a
/// cell rather than stepping one index at a time - skipping the unblocked
/// stretch keeps the open-set small and the path well-formed.
///
/// `run(...)` returns both the reconstructed polyline AND the goal `gScore`
/// so callers ranking candidate routes (flex-anchor selection) can compare
/// the A*-internal cost directly. There is no second cost function: A*'s
/// gScore is the single source of truth.
enum PolicyCanvasVisibilityAStar {
  static func run(
    gridXs: [CGFloat],
    gridYs: [CGFloat],
    sourceIndex: PolicyCanvasGridIndex,
    targetIndex: PolicyCanvasGridIndex,
    obstacles: [CGRect]
  ) -> (points: [CGPoint], cost: CGFloat)? {
    guard !gridXs.isEmpty, !gridYs.isEmpty else {
      return nil
    }
    let start = PolicyCanvasAStarState(index: sourceIndex, direction: .start)
    var openHeap = PolicyCanvasMinHeap<PolicyCanvasAStarState>()
    let initialPriority = heuristic(
      from: sourceIndex,
      to: targetIndex,
      gridXs: gridXs,
      gridYs: gridYs
    )
    openHeap.push(start, priority: initialPriority)
    var gScore: [PolicyCanvasAStarState: CGFloat] = [start: 0]
    var cameFrom: [PolicyCanvasAStarState: PolicyCanvasAStarState] = [:]
    var closed: Set<PolicyCanvasAStarState> = []
    while let current = openHeap.pop() {
      if current.index == targetIndex {
        let points = reconstruct(
          end: current,
          cameFrom: cameFrom,
          gridXs: gridXs,
          gridYs: gridYs
        )
        return (points, gScore[current] ?? .infinity)
      }
      if closed.contains(current) {
        continue
      }
      closed.insert(current)
      let currentG = gScore[current] ?? .infinity
      let neighbors = expand(
        state: current,
        gridXs: gridXs,
        gridYs: gridYs,
        obstacles: obstacles
      )
      for (next, stepCost) in neighbors {
        let tentative = currentG + stepCost
        let existing = gScore[next] ?? .infinity
        guard tentative < existing else {
          continue
        }
        gScore[next] = tentative
        cameFrom[next] = current
        let priority =
          tentative
          + heuristic(
            from: next.index,
            to: targetIndex,
            gridXs: gridXs,
            gridYs: gridYs
          )
        openHeap.push(next, priority: priority)
      }
    }
    return nil
  }

  private static func heuristic(
    from: PolicyCanvasGridIndex,
    to: PolicyCanvasGridIndex,
    gridXs: [CGFloat],
    gridYs: [CGFloat]
  ) -> CGFloat {
    abs(gridXs[from.x] - gridXs[to.x]) + abs(gridYs[from.y] - gridYs[to.y])
  }

  private static func reconstruct(
    end: PolicyCanvasAStarState,
    cameFrom: [PolicyCanvasAStarState: PolicyCanvasAStarState],
    gridXs: [CGFloat],
    gridYs: [CGFloat]
  ) -> [CGPoint] {
    var points: [CGPoint] = []
    var cursor: PolicyCanvasAStarState? = end
    while let state = cursor {
      points.append(CGPoint(x: gridXs[state.index.x], y: gridYs[state.index.y]))
      cursor = cameFrom[state]
    }
    return points.reversed()
  }

  private static func expand(
    state: PolicyCanvasAStarState,
    gridXs: [CGFloat],
    gridYs: [CGFloat],
    obstacles: [CGRect]
  ) -> [(PolicyCanvasAStarState, CGFloat)] {
    var results: [(PolicyCanvasAStarState, CGFloat)] = []
    let here = CGPoint(x: gridXs[state.index.x], y: gridYs[state.index.y])
    for offset in [-1, 1] {
      let neighborX = state.index.x + offset
      guard neighborX >= 0, neighborX < gridXs.count else {
        continue
      }
      let dest = CGPoint(x: gridXs[neighborX], y: here.y)
      guard !segmentBlocked(from: here, to: dest, obstacles: obstacles) else {
        continue
      }
      let stepCost = abs(dest.x - here.x) + bendCost(from: state.direction, to: .horizontal)
      let next = PolicyCanvasAStarState(
        index: PolicyCanvasGridIndex(x: neighborX, y: state.index.y),
        direction: .horizontal
      )
      results.append((next, stepCost))
    }
    for offset in [-1, 1] {
      let neighborY = state.index.y + offset
      guard neighborY >= 0, neighborY < gridYs.count else {
        continue
      }
      let dest = CGPoint(x: here.x, y: gridYs[neighborY])
      guard !segmentBlocked(from: here, to: dest, obstacles: obstacles) else {
        continue
      }
      let stepCost = abs(dest.y - here.y) + bendCost(from: state.direction, to: .vertical)
      let next = PolicyCanvasAStarState(
        index: PolicyCanvasGridIndex(x: state.index.x, y: neighborY),
        direction: .vertical
      )
      results.append((next, stepCost))
    }
    return results
  }

  private static func bendCost(
    from: PolicyCanvasAStarDirection,
    to: PolicyCanvasAStarDirection
  ) -> CGFloat {
    if from == .start || from == to {
      return 0
    }
    return PolicyCanvasVisibilityRouter.bendPenalty
  }

  // Grazing is intentionally allowed: a segment exactly along an obstacle's
  // border (rect.minY == from.y for a horizontal segment along the top edge,
  // etc.) is NOT blocked. Obstacle rects are typically inset from the real
  // node frame by a clearance, so a grazing route still keeps visual
  // distance from the node. Tightening to `<=`/`>=` would force a redundant
  // detour around every edge-aligned lane.
  static func segmentBlocked(from: CGPoint, to: CGPoint, obstacles: [CGRect]) -> Bool {
    let horizontal = abs(from.y - to.y) < 0.0001
    let minX = min(from.x, to.x)
    let maxX = max(from.x, to.x)
    let minY = min(from.y, to.y)
    let maxY = max(from.y, to.y)
    for rect in obstacles {
      if horizontal {
        if rect.minY < from.y && rect.maxY > from.y
          && rect.minX < maxX && rect.maxX > minX
        {
          return true
        }
      } else {
        if rect.minX < from.x && rect.maxX > from.x
          && rect.minY < maxY && rect.maxY > minY
        {
          return true
        }
      }
    }
    return false
  }
}

/// Minimal binary-heap priority queue used by A*. Inline implementation avoids
/// depending on a separate Collections package and keeps the router self-
/// contained. Cost is O(log n) push/pop; storage is an array of (priority,
/// element) tuples.
struct PolicyCanvasMinHeap<Element> {
  private var storage: [(priority: CGFloat, element: Element)] = []

  var isEmpty: Bool {
    storage.isEmpty
  }

  mutating func push(_ element: Element, priority: CGFloat) {
    storage.append((priority, element))
    siftUp(from: storage.count - 1)
  }

  mutating func pop() -> Element? {
    guard !storage.isEmpty else {
      return nil
    }
    storage.swapAt(0, storage.count - 1)
    let removed = storage.removeLast()
    if !storage.isEmpty {
      siftDown(from: 0)
    }
    return removed.element
  }

  private mutating func siftUp(from start: Int) {
    var index = start
    while index > 0 {
      let parent = (index - 1) / 2
      guard storage[index].priority < storage[parent].priority else {
        return
      }
      storage.swapAt(index, parent)
      index = parent
    }
  }

  private mutating func siftDown(from start: Int) {
    var index = start
    let count = storage.count
    while true {
      let left = (2 * index) + 1
      let right = (2 * index) + 2
      var smallest = index
      if left < count, storage[left].priority < storage[smallest].priority {
        smallest = left
      }
      if right < count, storage[right].priority < storage[smallest].priority {
        smallest = right
      }
      if smallest == index {
        return
      }
      storage.swapAt(index, smallest)
      index = smallest
    }
  }
}

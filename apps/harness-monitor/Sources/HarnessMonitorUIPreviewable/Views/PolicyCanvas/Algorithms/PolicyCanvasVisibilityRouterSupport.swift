/// Grid coordinate as (xIndex, yIndex) into the router's sorted axis arrays.
struct PolicyCanvasGridIndex: Hashable {
  let x: Int
  let y: Int
}

/// A* state for orthogonal routing. Direction tracks how the path arrived at
/// the current cell so bend penalties only apply on actual axis changes.
struct PolicyCanvasAStarState: Hashable {
  let index: PolicyCanvasGridIndex
  let direction: PolicyCanvasAStarDirection
}

enum PolicyCanvasAStarDirection: Hashable {
  case start
  case horizontal
  case vertical
}

import os

/// Router-decision log. Only the *fallback* path emits a line - A* success
/// is the expected case and a per-frame "solved" log would flood Console.
/// The fallback line names the reason so an operator looking at a
/// misshapen polyline can grep the log and confirm which path produced it
/// (silent supervision becomes observable supervision).
let policyCanvasRouterLog = Logger(
  subsystem: "io.harnessmonitor",
  category: "policy-canvas.router"
)

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

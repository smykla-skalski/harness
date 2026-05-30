import SwiftUI

// Dominant axis-aligned segments of an edge route, used by the displayed-route
// clearance passes to slide a route's longest horizontal or vertical run onto a
// bundle lane. Each carries the segment's start index in `route.points`, the
// fixed axis coordinate, and the run length (or the low/high span for the
// interior horizontal descent pass).

struct PolicyCanvasDominantHorizontalSegment {
  let index: Int
  let y: CGFloat
  let length: CGFloat
}

struct PolicyCanvasDominantVerticalSegment {
  let index: Int
  let x: CGFloat
  let length: CGFloat
}

struct PolicyCanvasDominantHorizontalSpan {
  let index: Int
  let y: CGFloat
  let low: CGFloat
  let high: CGFloat
}

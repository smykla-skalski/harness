import SwiftUI

struct PolicyCanvasDottedGrid: View {
  let spacing: CGFloat

  var body: some View {
    Canvas { context, size in
      let dot = Path(
        ellipseIn: CGRect(
          x: 0,
          y: 0,
          width: 1.5,
          height: 1.5
        )
      )
      let xValues = stride(from: CGFloat(0), through: size.width, by: max(8, spacing))
      let yValues = stride(from: CGFloat(0), through: size.height, by: max(8, spacing))
      for x in xValues {
        for y in yValues {
          context.translateBy(x: x, y: y)
          context.fill(dot, with: .color(.white.opacity(0.13)))
          context.translateBy(x: -x, y: -y)
        }
      }
    }
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.06, green: 0.07, blue: 0.10),
          Color(red: 0.03, green: 0.04, blue: 0.06),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    // `drawingGroup(opaque: true)` is intentionally NOT applied here. The
    // dot pitch is keyed on `spacing = gridSize * zoom`, so the rasterized
    // bitmap would be invalidated and re-allocated on every pinch tick
    // (~60-120Hz). The pan win the cache used to deliver is outweighed by
    // the per-frame reallocation cost during pinch. Re-introduction requires
    // splitting the grid into a fixed-pitch raster layer plus a separate
    // scaleEffect, so pinch updates a single transform instead of forcing a
    // re-record. Pair the change with a trace recorded under both pan and
    // pinch — until that rig exists (see `tmp/wave-4m-perf-rig-gap.md`),
    // ship the un-rasterized grid.
  }
}

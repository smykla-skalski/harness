import SwiftUI

struct HarnessCornerAnimation: View {
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    if reduceMotion {
      staticFallback
    } else {
      animatedCanvas
    }
  }

  private var staticFallback: some View {
    Canvas { context, size in
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      for i in 0..<3 {
        let radius = ringRadius(index: i, size: size)
        let color = ringColor(index: i)
        let circle = Path(ellipseIn: CGRect(
          x: center.x - radius,
          y: center.y - radius,
          width: radius * 2,
          height: radius * 2
        ))
        context.stroke(circle, with: .color(color), lineWidth: 1.5)
      }
    }
    .accessibilityHidden(true)
  }

  private var animatedCanvas: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
      let elapsed = timeline.date.timeIntervalSinceReferenceDate
      Canvas { context, size in
        drawOrbitingRings(context: context, size: size, time: elapsed)
      }
    }
    .accessibilityHidden(true)
  }

  private func drawOrbitingRings(
    context: GraphicsContext,
    size: CGSize,
    time: Double
  ) {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)

    for i in 0..<3 {
      let index = Double(i)
      let baseRadius = ringRadius(index: i, size: size)
      let speed = 0.4 + index * 0.15
      let phase = index * .pi * 2 / 3

      let wobble = sin(time * speed + phase) * 4
      let radius = baseRadius + wobble

      let rotation = Angle(radians: time * (0.3 + index * 0.1) + phase)
      let tilt = 0.35 + index * 0.15

      var ringContext = context
      ringContext.translateBy(x: center.x, y: center.y)
      ringContext.rotate(by: rotation)

      let ellipse = Path(ellipseIn: CGRect(
        x: -radius,
        y: -radius * tilt,
        width: radius * 2,
        height: radius * 2 * tilt
      ))

      let color = ringColor(index: i)
      ringContext.stroke(ellipse, with: .color(color), lineWidth: 1.5)

      let dotAngle = time * (0.8 + index * 0.2) + phase
      let dotX = cos(dotAngle) * radius
      let dotY = sin(dotAngle) * radius * tilt
      let dotSize: CGFloat = 4

      let dot = Path(ellipseIn: CGRect(
        x: dotX - dotSize / 2,
        y: dotY - dotSize / 2,
        width: dotSize,
        height: dotSize
      ))
      ringContext.fill(dot, with: .color(color.opacity(0.9)))
    }
  }

  private func ringRadius(index: Int, size: CGSize) -> CGFloat {
    let minDimension = min(size.width, size.height)
    let base = minDimension * 0.25
    return base + CGFloat(index) * minDimension * 0.1
  }

  private func ringColor(index: Int) -> Color {
    switch index {
    case 0: HarnessMonitorTheme.accent.opacity(0.6)
    case 1: HarnessMonitorTheme.success.opacity(0.5)
    default: HarnessMonitorTheme.warmAccent.opacity(0.4)
    }
  }
}

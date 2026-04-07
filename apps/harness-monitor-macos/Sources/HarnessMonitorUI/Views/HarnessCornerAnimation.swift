import SwiftUI

struct HarnessCornerAnimation: View {
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @Environment(\.colorScheme)
  private var colorScheme

  private static let particleCount = 5
  private static let trailLength = 6

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
      for i in 0..<Self.particleCount {
        let angle = Double(i) * .pi * 2 / Double(Self.particleCount)
        let orbit = orbitRadius(index: i, size: size)
        let position = CGPoint(
          x: center.x + cos(angle) * orbit,
          y: center.y + sin(angle) * orbit
        )
        drawParticle(
          in: &context,
          at: position,
          color: particleColor(index: i),
          coreRadius: coreRadius(size: size),
          glowRadius: glowRadius(size: size)
        )
      }
    }
    .accessibilityHidden(true)
  }

  private var animatedCanvas: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
      let elapsed = timeline.date.timeIntervalSinceReferenceDate
      Canvas { context, size in
        drawScene(context: &context, size: size, time: elapsed)
      }
    }
    .accessibilityHidden(true)
  }

  private func drawScene(
    context: inout GraphicsContext,
    size: CGSize,
    time: Double
  ) {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let core = coreRadius(size: size)
    let glow = glowRadius(size: size)

    for i in 0..<Self.particleCount {
      let index = Double(i)
      let speed = 0.25 + index * 0.08
      let phase = index * .pi * 2 / Double(Self.particleCount)
      let orbit = orbitRadius(index: i, size: size)

      let breathe = sin(time * 0.6 + phase) * orbit * 0.08
      let currentOrbit = orbit + breathe

      let angle = time * speed + phase
      let color = particleColor(index: i)

      for trail in (0..<Self.trailLength).reversed() {
        let trailOffset = Double(trail) * 0.12
        let trailAngle = angle - trailOffset * speed
        let trailFade = 1.0 - Double(trail) / Double(Self.trailLength)
        let position = CGPoint(
          x: center.x + cos(trailAngle) * currentOrbit,
          y: center.y + sin(trailAngle) * currentOrbit
        )
        drawParticle(
          in: &context,
          at: position,
          color: color.opacity(trailFade),
          coreRadius: core * trailFade,
          glowRadius: glow * trailFade
        )
      }
    }
  }

  private func drawParticle(
    in context: inout GraphicsContext,
    at position: CGPoint,
    color: Color,
    coreRadius: CGFloat,
    glowRadius: CGFloat
  ) {
    let outerGlow = Path(ellipseIn: CGRect(
      x: position.x - glowRadius,
      y: position.y - glowRadius,
      width: glowRadius * 2,
      height: glowRadius * 2
    ))
    context.fill(outerGlow, with: .color(color.opacity(0.12)))

    let innerGlow = Path(ellipseIn: CGRect(
      x: position.x - glowRadius * 0.5,
      y: position.y - glowRadius * 0.5,
      width: glowRadius,
      height: glowRadius
    ))
    context.fill(innerGlow, with: .color(color.opacity(0.25)))

    let corePath = Path(ellipseIn: CGRect(
      x: position.x - coreRadius,
      y: position.y - coreRadius,
      width: coreRadius * 2,
      height: coreRadius * 2
    ))
    context.fill(corePath, with: .color(color.opacity(0.85)))

    let hotspot = Path(ellipseIn: CGRect(
      x: position.x - coreRadius * 0.4,
      y: position.y - coreRadius * 0.4,
      width: coreRadius * 0.8,
      height: coreRadius * 0.8
    ))
    context.fill(hotspot, with: .color(.white.opacity(0.5)))
  }

  private func orbitRadius(index: Int, size: CGSize) -> CGFloat {
    let minDimension = min(size.width, size.height)
    let base = minDimension * 0.2
    let spread = minDimension * 0.06
    return base + CGFloat(index) * spread
  }

  private func coreRadius(size: CGSize) -> CGFloat {
    min(size.width, size.height) * 0.03
  }

  private func glowRadius(size: CGSize) -> CGFloat {
    min(size.width, size.height) * 0.09
  }

  private func particleColor(index: Int) -> Color {
    switch index % 5 {
    case 0: HarnessMonitorTheme.accent
    case 1: HarnessMonitorTheme.success
    case 2: HarnessMonitorTheme.warmAccent
    case 3: HarnessMonitorTheme.accent.opacity(0.8)
    default: HarnessMonitorTheme.success.opacity(0.7)
    }
  }
}

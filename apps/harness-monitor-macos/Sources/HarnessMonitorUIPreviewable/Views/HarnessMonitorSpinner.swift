import SwiftUI

struct HarnessMonitorSpinner: View {
  @ScaledMetric private var scaledSize: CGFloat
  private let tint: Color
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  init(size: CGFloat = 16, tint: Color = .secondary) {
    _scaledSize = ScaledMetric(wrappedValue: size)
    self.tint = tint
  }

  var body: some View {
    if reduceMotion {
      ring(rotationDegrees: 0)
        .accessibilityHidden(true)
    } else {
      TimelineView(.animation) { context in
        ring(rotationDegrees: rotationDegrees(at: context.date))
      }
      .accessibilityHidden(true)
    }
  }

  private func ring(rotationDegrees: Double) -> some View {
    Circle()
      .trim(from: 0.15, to: 0.85)
      .stroke(
        AngularGradient(
          colors: [tint.opacity(0.1), tint],
          center: .center,
          startAngle: .degrees(0),
          endAngle: .degrees(270)
        ),
        style: StrokeStyle(lineWidth: 2, lineCap: .round)
      )
      .frame(width: scaledSize, height: scaledSize)
      .rotationEffect(.degrees(rotationDegrees))
  }

  private func rotationDegrees(at date: Date) -> Double {
    let cycleDuration = 0.8
    let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration)
    return phase / cycleDuration * 360
  }
}

import SwiftUI

struct HarnessSpinner: View {
  @ScaledMetric private var scaledSize: CGFloat
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isSpinning = false

  init(size: CGFloat = 16) {
    _scaledSize = ScaledMetric(wrappedValue: size)
  }

  var body: some View {
    Circle()
      .trim(from: 0.15, to: 0.85)
      .stroke(
        AngularGradient(
          colors: [.secondary.opacity(0.1), .secondary],
          center: .center,
          startAngle: .degrees(0),
          endAngle: .degrees(270)
        ),
        style: StrokeStyle(lineWidth: 2, lineCap: .round)
      )
      .frame(width: scaledSize, height: scaledSize)
      .rotationEffect(.degrees(reduceMotion ? 0 : (isSpinning ? 360 : 0)))
      .animation(
        reduceMotion ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false),
        value: isSpinning
      )
      .onAppear { isSpinning = true }
      .accessibilityHidden(true)
  }
}

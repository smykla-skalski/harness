import SwiftUI

struct HarnessSpinner: View {
  let size: CGFloat
  @State private var isSpinning = false

  init(size: CGFloat = 16) {
    self.size = size
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
      .frame(width: size, height: size)
      .rotationEffect(.degrees(isSpinning ? 360 : 0))
      .animation(
        .linear(duration: 0.8).repeatForever(autoreverses: false),
        value: isSpinning
      )
      .onAppear { isSpinning = true }
      .onDisappear { isSpinning = false }
      .accessibilityHidden(true)
  }
}

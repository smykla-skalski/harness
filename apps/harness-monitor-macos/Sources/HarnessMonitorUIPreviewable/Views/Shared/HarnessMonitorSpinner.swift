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
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
      let lineWidth = max(2, scaledSize * 0.06)
      ZStack {
        Circle()
          .stroke(tint.opacity(0.12), style: StrokeStyle(lineWidth: lineWidth))
        Circle()
          .trim(from: 0.15, to: 0.85)
          .stroke(
            tint,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
          )
          .rotationEffect(.degrees(rotationAngle(for: context.date)))
      }
      .frame(width: scaledSize, height: scaledSize)
    }
    .accessibilityHidden(true)
  }

  private func rotationAngle(for date: Date) -> Double {
    guard !reduceMotion else { return 0 }
    return date.timeIntervalSinceReferenceDate / 0.8 * 360
  }
}

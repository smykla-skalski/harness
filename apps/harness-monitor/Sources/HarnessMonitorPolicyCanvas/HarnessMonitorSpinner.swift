import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct HarnessMonitorSpinner: View {
  @ScaledMetric private var scaledSize: CGFloat
  private let tint: Color

  init(size: CGFloat = 16, tint: Color = .secondary) {
    _scaledSize = ScaledMetric(wrappedValue: size)
    self.tint = tint
  }

  var body: some View {
    Image(systemName: "hourglass")
      .font(.system(size: scaledSize, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: scaledSize, height: scaledSize)
      .accessibilityHidden(true)
  }
}

import SwiftUI

struct SessionToolbarButtonStyle: ButtonStyle {
  struct Metrics: Equatable {
    static let cornerRadius: CGFloat = 8
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 5
    static let minHeight: CGFloat = 28
    static let iconWidth: CGFloat = 16
    static let pressedScale = 0.98
    static let animationDuration = 0.14

    static func resolved(fontScale: CGFloat) -> ResolvedMetrics {
      ResolvedMetrics(fontScale: fontScale)
    }
  }

  struct ResolvedMetrics: Equatable {
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let minHeight: CGFloat
    let iconWidth: CGFloat

    init(fontScale: CGFloat) {
      let scale = SessionWindowFontScale.metricsScale(for: fontScale)
      cornerRadius = Metrics.cornerRadius * min(scale, 1.25)
      horizontalPadding = Metrics.horizontalPadding * min(scale, 1.45)
      verticalPadding = Metrics.verticalPadding * min(scale, 1.45)
      minHeight = max(Metrics.minHeight, Metrics.minHeight * scale)
      iconWidth = max(Metrics.iconWidth, Metrics.iconWidth * min(scale, 1.35))
    }
  }

  var isSelected = false

  func makeBody(configuration: Configuration) -> some View {
    SessionToolbarButtonStyleBody(
      configuration: configuration,
      isSelected: isSelected
    )
  }
}

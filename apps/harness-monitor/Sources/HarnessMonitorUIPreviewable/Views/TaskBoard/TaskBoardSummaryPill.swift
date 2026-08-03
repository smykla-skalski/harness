import SwiftUI

struct TaskBoardSummaryPill: View {
  enum Chrome {
    case content
    case control
  }

  let value: String
  let label: String
  let systemImage: String?
  let tint: Color
  let chrome: Chrome
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardOverviewMetrics {
    TaskBoardOverviewMetrics(fontScale: fontScale)
  }

  // Pills are rendered in dense clusters across the dashboard
  // (`TaskBoardOperationsPanel` lays them out as Items / Providers /
  // Ops / Plans summary chips, repeated per row). Each `.scaledFont`
  // call plants a `ScaledFontModifier` that subscribes per text node
  // to `\.fontScale`, and r17 traced this as a contributor to the
  // `Conditional View Value square.split.diagonal` 18,956-edge
  // self-loop fanned via `EnvironmentWriter: Font?`. Subscribe once
  // and apply precomputed fonts.
  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var iconFont: Font {
    HarnessMonitorTextSize.scaledFont(.system(size: 8.6, weight: .semibold), by: fontScale)
  }

  private var captionBold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.bold), by: fontScale)
  }

  init(
    value: String,
    label: String,
    systemImage: String? = nil,
    tint: Color = HarnessMonitorTheme.secondaryInk,
    chrome: Chrome = .content
  ) {
    self.value = value
    self.label = label
    self.systemImage = systemImage
    self.tint = tint
    self.chrome = chrome
  }

  var body: some View {
    let captionFont = captionFont
    let iconFont = iconFont
    let captionBold = captionBold
    let content = HStack(
      alignment: .firstTextBaseline,
      spacing: HarnessMonitorTheme.spacingXS
    ) {
      if let systemImage {
        Text(Image(systemName: systemImage))
          .font(iconFont)
          .accessibilityHidden(true)
      }
      Text(label)
        .font(captionFont)
      Text(value)
        .font(captionBold)
        .monospacedDigit()
    }
    .foregroundStyle(tint)
    .padding(.horizontal, metrics.summaryPillHorizontalPadding)
    .padding(.vertical, metrics.summaryPillVerticalPadding)
    switch chrome {
    case .content:
      content.harnessContentPill(tint: tint)
    case .control:
      content.harnessControlPill(tint: tint)
    }
  }
}

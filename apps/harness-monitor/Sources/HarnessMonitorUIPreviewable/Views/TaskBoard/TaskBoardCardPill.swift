import SwiftUI

enum TaskBoardCardPillDensity {
  case standard
  case compact
}

extension EnvironmentValues {
  @Entry var taskBoardCardPillDensity: TaskBoardCardPillDensity = .standard
}

struct TaskBoardCardPill: View {
  let label: String
  let tint: Color
  var systemImage: String?
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.taskBoardCardPillDensity)
  private var pillDensity

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var pillFont: Font {
    switch pillDensity {
    case .standard:
      HarnessMonitorTextSize.scaledFont(.caption2.weight(.bold), by: fontScale)
    case .compact:
      HarnessMonitorTextSize.scaledFont(
        .system(size: 8, weight: .semibold),
        by: fontScale
      )
    }
  }
  private var contentSpacing: CGFloat {
    switch pillDensity {
    case .standard:
      HarnessMonitorTheme.spacingXS
    case .compact:
      metrics.rowTextSpacing * 0.5
    }
  }
  private var horizontalPadding: CGFloat {
    switch pillDensity {
    case .standard:
      metrics.pillHorizontalPadding
    case .compact:
      max(HarnessMonitorTheme.spacingXS, metrics.pillHorizontalPadding * 0.5)
    }
  }
  private var compactVerticalPadding: CGFloat {
    max(1, metrics.pillVerticalPadding * 0.25)
  }
  private var compactOpticalInsetAdjustment: CGFloat { 0.5 }
  private var verticalInsets: EdgeInsets {
    switch pillDensity {
    case .standard:
      EdgeInsets(
        top: metrics.pillVerticalPadding,
        leading: 0,
        bottom: metrics.pillVerticalPadding,
        trailing: 0
      )
    case .compact:
      EdgeInsets(
        top: compactVerticalPadding + compactOpticalInsetAdjustment,
        leading: 0,
        bottom: max(0, compactVerticalPadding - compactOpticalInsetAdjustment),
        trailing: 0
      )
    }
  }

  var body: some View {
    let pillFont = pillFont
    return HStack(spacing: contentSpacing) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(pillFont)
          .accessibilityHidden(true)
      }
      Text(label)
        .font(pillFont)
    }
    .foregroundStyle(tint)
    .lineLimit(1)
    .padding(.horizontal, horizontalPadding)
    .padding(verticalInsets)
    .harnessContentPill(tint: tint)
  }
}

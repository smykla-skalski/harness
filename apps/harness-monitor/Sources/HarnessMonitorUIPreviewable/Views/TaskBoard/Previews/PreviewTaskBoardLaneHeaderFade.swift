import HarnessMonitorKit
import SwiftUI

#Preview("Task Board Lane Header Fade") {
  HStack(alignment: .top, spacing: 24) {
    LaneHeaderFadeSample(caption: "Rest", fade: .previewRest)
    LaneHeaderFadeSample(caption: "Hover", fade: .previewHover)
    LaneHeaderFadeSample(caption: "Press", fade: .previewPress)
  }
  .padding(24)
}

/// Pins the fade instead of driving it from a pointer, so hover and press are
/// visible in a static render.
private struct LaneHeaderFadeSample: View {
  let caption: String
  let fade: TaskBoardLaneHeaderFade
  @Environment(\.fontScale)
  private var fontScale

  private let lane = TaskBoardInboxLane.inProgress

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(caption)
        .font(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      laneCard
    }
  }

  private var laneCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      TaskBoardLaneHeader(
        lane: lane,
        count: 6,
        collapseOverridesRawValue: .constant("")
      )
      .background {
        TaskBoardLaneHeaderFadeLayer(
          color: taskBoardLaneColor(for: lane),
          cornerRadius: metrics.cardCornerRadius,
          fade: fade
        )
      }

      TaskBoardEmptyLane(lane: lane)
        .padding(.horizontal, metrics.laneInnerPadding)
        .padding(.top, metrics.laneHeaderBodyTopPadding)
        .padding(.bottom, metrics.laneInnerPadding)
    }
    .taskBoardLaneColumnChrome(lane: lane)
  }
}

extension TaskBoardLaneHeaderFade {
  fileprivate static let previewRest = Self(
    isHovered: false,
    isPressed: false,
    reduceTransparency: false,
    increasesContrast: false
  )

  fileprivate static let previewHover = Self(
    isHovered: true,
    isPressed: false,
    reduceTransparency: false,
    increasesContrast: false
  )

  fileprivate static let previewPress = Self(
    isHovered: true,
    isPressed: true,
    reduceTransparency: false,
    increasesContrast: false
  )
}

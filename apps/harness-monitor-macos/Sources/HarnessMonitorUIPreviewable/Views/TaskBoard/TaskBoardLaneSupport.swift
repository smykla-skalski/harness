import HarnessMonitorKit
import SwiftUI

struct TaskBoardLaneMetrics: Equatable {
  let laneSpacing: CGFloat
  let laneInnerPadding: CGFloat
  let laneWidth: CGFloat
  let laneMinHeight: CGFloat
  let laneBodyMinHeight: CGFloat
  let laneBodyTopPadding: CGFloat
  let headerIconWidth: CGFloat
  let headerHorizontalPadding: CGFloat
  let headerVerticalPadding: CGFloat
  let countHorizontalPadding: CGFloat
  let countVerticalPadding: CGFloat
  let emptyLaneMinHeight: CGFloat
  let overflowMinHeight: CGFloat
  let cardMinHeight: CGFloat
  let cardPadding: CGFloat
  let cardAccentWidth: CGFloat
  let cardMarkerSize: CGFloat
  let cardMarkerTopPadding: CGFloat
  let rowTextSpacing: CGFloat
  let pillHorizontalPadding: CGFloat
  let pillVerticalPadding: CGFloat
  let dragPreviewWidth: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    let denseScale = min(scale, 1.35)
    let broadScale = min(scale, 1.18)
    let heightScale = min(scale, 1.25)
    laneSpacing = HarnessMonitorTheme.spacingSM * denseScale
    laneInnerPadding = HarnessMonitorTheme.spacingSM * denseScale
    laneWidth = 304 * broadScale
    laneMinHeight = 400 * min(scale, 1.2)
    laneBodyMinHeight = 336 * min(scale, 1.2)
    laneBodyTopPadding = HarnessMonitorTheme.spacingXS * denseScale
    headerIconWidth = 18 * min(scale, 1.25)
    headerHorizontalPadding = HarnessMonitorTheme.spacingSM * denseScale
    headerVerticalPadding = 6 * denseScale
    countHorizontalPadding = HarnessMonitorTheme.spacingSM * denseScale
    countVerticalPadding = 2 * min(scale, 1.25)
    emptyLaneMinHeight = 96 * heightScale
    overflowMinHeight = 28 * denseScale
    cardMinHeight = 86 * heightScale
    cardPadding = HarnessMonitorTheme.spacingMD * denseScale
    cardAccentWidth = 3 * min(scale, 1.2)
    cardMarkerSize = 9 * min(scale, 1.25)
    cardMarkerTopPadding = 6 * min(scale, 1.25)
    rowTextSpacing = 3 * denseScale
    pillHorizontalPadding = 9 * denseScale
    pillVerticalPadding = 4 * denseScale
    dragPreviewWidth = 220 * broadScale
  }
}

enum TaskBoardLaneDropPolicy {
  static func moveFirstPayload(
    _ payloads: [TaskBoardItemDragPayload],
    to destination: TaskBoardInboxLane,
    move: (String, TaskBoardInboxLane) -> Bool
  ) -> Bool {
    guard let payload = payloads.first else {
      return false
    }
    guard payload.sourceLane != destination else {
      return false
    }
    return move(payload.itemID, destination)
  }
}

struct TaskBoardEmptyLane: View {
  let lane: TaskBoardInboxLane
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    Color.clear
      .frame(maxWidth: .infinity, minHeight: metrics.emptyLaneMinHeight)
      .accessibilityLabel("\(lane.title) lane empty")
  }
}

struct TaskBoardLaneOverflowRow: View {
  let hiddenCount: Int
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    if hiddenCount > 0 {
      Text("+\(hiddenCount) more")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(maxWidth: .infinity, minHeight: metrics.overflowMinHeight)
        .background(.background.opacity(0.36), in: .rect(cornerRadius: 6))
        .accessibilityLabel("\(hiddenCount) more task board items")
    }
  }
}

func taskBoardLaneColor(for lane: TaskBoardInboxLane) -> Color {
  switch lane {
  case .needsYou:
    HarnessMonitorTheme.danger
  case .ready:
    HarnessMonitorTheme.accent
  case .blocked:
    HarnessMonitorTheme.danger
  case .review:
    HarnessMonitorTheme.caution
  case .running:
    HarnessMonitorTheme.warmAccent
  case .backlog:
    HarnessMonitorTheme.accent
  }
}

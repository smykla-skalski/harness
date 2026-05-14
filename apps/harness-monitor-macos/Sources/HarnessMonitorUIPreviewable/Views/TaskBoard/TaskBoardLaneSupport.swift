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
  let headerBottomPadding: CGFloat
  let countHorizontalPadding: CGFloat
  let countVerticalPadding: CGFloat
  let emptyLaneMinHeight: CGFloat
  let overflowMinHeight: CGFloat
  let cardMinHeight: CGFloat
  let cardPadding: CGFloat
  let cardCornerRadius: CGFloat
  let cardMarkerSize: CGFloat
  let cardMarkerTopPadding: CGFloat
  let rowTextSpacing: CGFloat
  let pillHorizontalPadding: CGFloat
  let pillVerticalPadding: CGFloat
  let dragPreviewWidth: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    let denseScale = min(scale, 1.3)
    let broadScale = min(scale, 1.16)
    let heightScale = min(scale, 1.18)
    laneSpacing = HarnessMonitorTheme.spacingSM * denseScale
    laneInnerPadding = HarnessMonitorTheme.spacingMD * denseScale
    laneWidth = 288 * broadScale
    laneMinHeight = 352 * heightScale
    laneBodyMinHeight = 280 * heightScale
    laneBodyTopPadding = HarnessMonitorTheme.spacingSM * denseScale
    headerIconWidth = 18 * min(scale, 1.25)
    headerHorizontalPadding = 0
    headerVerticalPadding = 0
    headerBottomPadding = HarnessMonitorTheme.spacingSM * denseScale
    countHorizontalPadding = HarnessMonitorTheme.spacingSM * denseScale
    countVerticalPadding = HarnessMonitorTheme.spacingXS * min(scale, 1.2)
    emptyLaneMinHeight = 92 * heightScale
    overflowMinHeight = 28 * denseScale
    cardMinHeight = 80 * heightScale
    cardPadding = HarnessMonitorTheme.spacingMD * denseScale
    cardCornerRadius = HarnessMonitorTheme.cornerRadiusSM
    cardMarkerSize = 28 * min(scale, 1.15)
    cardMarkerTopPadding = 2 * denseScale
    rowTextSpacing = HarnessMonitorTheme.spacingXS * denseScale
    pillHorizontalPadding = HarnessMonitorTheme.pillPaddingH * denseScale
    pillVerticalPadding = HarnessMonitorTheme.pillPaddingV * min(scale, 1.2)
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

enum TaskBoardInboxDropPolicy {
  static func moveFirstPayload(
    _ payloads: [TaskBoardInboxItemDragPayload],
    to destination: TaskBoardInboxLane,
    move: (TaskBoardInboxItemDragPayload, TaskBoardInboxLane) -> Bool
  ) -> Bool {
    guard let payload = payloads.first else {
      return false
    }
    guard payload.sourceLane != destination else {
      return false
    }
    return move(payload, destination)
  }
}

struct TaskBoardEmptyLane: View {
  let lane: TaskBoardInboxLane
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    VStack(spacing: metrics.laneSpacing) {
      TaskBoardCardLeadingIcon(
        systemImage: lane.systemImage,
        tint: taskBoardLaneColor(for: lane)
      )
      Text("Nothing here")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, minHeight: metrics.emptyLaneMinHeight)
    .accessibilityElement(children: .ignore)
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
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: "ellipsis")
          .scaledFont(.caption.weight(.bold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityHidden(true)
        Text("+\(hiddenCount) more")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      .frame(maxWidth: .infinity, minHeight: metrics.overflowMinHeight)
      .background(
        .background.opacity(0.32),
        in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
      )
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
          .stroke(HarnessMonitorTheme.controlBorder.opacity(0.34), lineWidth: 1)
      }
      .accessibilityLabel("\(hiddenCount) more task board items")
    }
  }
}

struct TaskBoardCardLeadingIcon: View {
  let systemImage: String
  let tint: Color
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    Image(systemName: systemImage)
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(tint)
      .frame(width: metrics.cardMarkerSize, height: metrics.cardMarkerSize)
      .background(tint.opacity(0.16), in: Circle())
      .accessibilityHidden(true)
  }
}

struct TaskBoardCardPill: View {
  let label: String
  let tint: Color
  var systemImage: String?

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if let systemImage {
        Image(systemName: systemImage)
          .scaledFont(.caption2.weight(.bold))
          .accessibilityHidden(true)
      }
      Text(label)
        .scaledFont(.caption2.weight(.bold))
    }
    .foregroundStyle(tint)
    .lineLimit(1)
    .harnessPillPadding()
    .harnessContentPill(tint: tint)
  }
}

private struct TaskBoardCardChrome: ViewModifier {
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  func body(content: Content) -> some View {
    content
      .harnessInteractiveCardButtonStyle(cornerRadius: metrics.cardCornerRadius)
      .background(
        RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)
          .fill(
            AnyShapeStyle(
              .background.opacity(reduceTransparency ? 0.68 : 0.56)
            )
          )
      )
      .overlay {
        RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)
          .strokeBorder(
            HarnessMonitorTheme.controlBorder.opacity(
              colorSchemeContrast == .increased ? 0.74 : 0.52
            ),
            lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
          )
      }
  }
}

extension View {
  func taskBoardCardChrome() -> some View {
    modifier(TaskBoardCardChrome())
  }
}

struct TaskBoardLaneHeader: View {
  let lane: TaskBoardInboxLane
  let count: Int
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    HStack(spacing: metrics.laneSpacing) {
      Image(systemName: lane.systemImage)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(taskBoardLaneColor(for: lane))
        .frame(
          width: metrics.headerIconWidth + HarnessMonitorTheme.spacingMD,
          height: metrics.headerIconWidth + HarnessMonitorTheme.spacingMD
        )
        .background(taskBoardLaneColor(for: lane).opacity(0.14), in: Circle())
        .accessibilityHidden(true)
      Text(lane.title)
        .scaledFont(.subheadline.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
      Spacer(minLength: metrics.laneSpacing)
      Text("\(count)")
        .scaledFont(.caption.weight(.bold))
        .foregroundStyle(taskBoardLaneColor(for: lane))
        .monospacedDigit()
        .padding(.horizontal, metrics.countHorizontalPadding)
        .padding(.vertical, metrics.countVerticalPadding)
        .background(taskBoardLaneColor(for: lane).opacity(0.14), in: .capsule)
        .overlay {
          Capsule()
            .stroke(taskBoardLaneColor(for: lane).opacity(0.26), lineWidth: 1)
        }
    }
    .padding(.horizontal, metrics.headerHorizontalPadding)
    .padding(.vertical, metrics.headerVerticalPadding)
    .padding(.bottom, metrics.headerBottomPadding)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(HarnessMonitorTheme.controlBorder.opacity(0.24))
        .frame(height: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

private struct TaskBoardLaneColumnChrome: ViewModifier {
  let lane: TaskBoardInboxLane
  let isDropTargeted: Bool
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, metrics.laneInnerPadding)
      .padding(.vertical, metrics.laneInnerPadding)
      .frame(width: metrics.laneWidth, alignment: .topLeading)
      .frame(minHeight: metrics.laneMinHeight, alignment: .topLeading)
      .background {
        RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)
          .fill(laneFill)
      }
      .overlay {
        RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)
          .strokeBorder(laneStrokeColor, lineWidth: laneStrokeWidth)
      }
      .overlay(alignment: .top) {
        Rectangle()
          .fill(laneAccentColor)
          .padding(.horizontal, metrics.laneInnerPadding)
          .frame(height: max(2, laneStrokeWidth + 1))
      }
  }

  private var laneFill: AnyShapeStyle {
    if isDropTargeted {
      return AnyShapeStyle(taskBoardLaneColor(for: lane).opacity(reduceTransparency ? 0.18 : 0.12))
    }
    return AnyShapeStyle(.background.opacity(reduceTransparency ? 0.72 : 0.6))
  }

  private var laneStrokeColor: Color {
    if isDropTargeted {
      return taskBoardLaneColor(for: lane).opacity(colorSchemeContrast == .increased ? 0.84 : 0.62)
    }
    return HarnessMonitorTheme.controlBorder.opacity(
      colorSchemeContrast == .increased ? 0.78 : 0.54
    )
  }

  private var laneAccentColor: Color {
    if isDropTargeted {
      return taskBoardLaneColor(for: lane).opacity(colorSchemeContrast == .increased ? 0.88 : 0.64)
    }
    return taskBoardLaneColor(for: lane).opacity(colorSchemeContrast == .increased ? 0.72 : 0.48)
  }

  private var laneStrokeWidth: CGFloat {
    colorSchemeContrast == .increased ? 2 : 1
  }
}

private struct TaskBoardLaneBodyChrome: ViewModifier {
  let lane: TaskBoardInboxLane
  let isDropTargeted: Bool
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, minHeight: metrics.laneBodyMinHeight, alignment: .top)
      .padding(.top, metrics.laneBodyTopPadding)
      .background {
        if isDropTargeted {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
            .fill(
              taskBoardLaneColor(for: lane)
                .opacity(reduceTransparency ? 0.14 : 0.08)
            )
        }
      }
  }
}

extension View {
  func taskBoardLaneColumnChrome(
    lane: TaskBoardInboxLane,
    isDropTargeted: Bool = false
  ) -> some View {
    modifier(TaskBoardLaneColumnChrome(lane: lane, isDropTargeted: isDropTargeted))
  }

  func taskBoardLaneBodyChrome(
    lane: TaskBoardInboxLane,
    isDropTargeted: Bool = false
  ) -> some View {
    modifier(TaskBoardLaneBodyChrome(lane: lane, isDropTargeted: isDropTargeted))
  }
}

func taskBoardLaneColor(for lane: TaskBoardInboxLane) -> Color {
  switch lane {
  case .needsYou:
    HarnessMonitorTheme.warmAccent
  case .ready:
    HarnessMonitorTheme.accent
  case .blocked:
    HarnessMonitorTheme.danger
  case .review:
    HarnessMonitorTheme.caution
  case .running:
    HarnessMonitorTheme.success
  case .backlog:
    HarnessMonitorTheme.secondaryInk
  }
}

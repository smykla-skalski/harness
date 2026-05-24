import HarnessMonitorKit
import SwiftUI

struct TaskBoardLaneHeader: View {
  let lane: TaskBoardInboxLane
  let count: Int
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var iconFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.subheadline.weight(.semibold), by: fontScale)
  }
  private var countFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.bold), by: fontScale)
  }

  var body: some View {
    HStack(spacing: metrics.laneSpacing) {
      Image(systemName: lane.systemImage)
        .font(iconFont)
        .foregroundStyle(taskBoardLaneColor(for: lane))
        .frame(
          width: metrics.headerIconWidth + HarnessMonitorTheme.spacingMD,
          height: metrics.headerIconWidth + HarnessMonitorTheme.spacingMD
        )
        .background(taskBoardLaneColor(for: lane).opacity(0.14), in: Circle())
        .accessibilityHidden(true)
      Text(lane.title)
        .font(titleFont)
        .foregroundStyle(HarnessMonitorTheme.ink)
      Spacer(minLength: metrics.laneSpacing)
      Text("\(count)")
        .font(countFont)
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
      .frame(
        minWidth: metrics.laneWidth,
        maxWidth: .infinity,
        minHeight: metrics.laneFixedHeight,
        idealHeight: metrics.laneFixedHeight,
        maxHeight: .infinity,
        alignment: .topLeading
      )
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
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
  case .done:
    HarnessMonitorTheme.success
  case .running:
    HarnessMonitorTheme.success
  case .backlog:
    HarnessMonitorTheme.secondaryInk
  }
}

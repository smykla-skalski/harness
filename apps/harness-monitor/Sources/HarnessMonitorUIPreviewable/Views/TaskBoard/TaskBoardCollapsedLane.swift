import HarnessMonitorKit
import SwiftUI

struct TaskBoardCollapsedLane: View {
  let lane: TaskBoardInboxLane
  let count: Int
  @Binding var collapseOverridesRawValue: String
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var countFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.bold), by: fontScale)
  }
  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.title3.weight(.semibold), by: fontScale)
  }
  private var collapsedButtonWidth: CGFloat {
    metrics.laneCollapsedWidth
  }
  private var collapsedContentWidth: CGFloat {
    max(0, metrics.laneCollapsedWidth - (2 * metrics.laneCollapsedInnerPadding))
  }
  private var collapsedButtonTopPadding: CGFloat {
    metrics.laneCollapsedInnerPadding + metrics.laneCollapsedContentTopPadding
  }

  var body: some View {
    Button(action: expand) {
      VStack(spacing: metrics.laneCollapsedContentTopPadding) {
        Text("\(count)")
          .font(countFont)
          .foregroundStyle(HarnessMonitorTheme.ink)
          .monospacedDigit()
          .frame(
            width: metrics.laneCollapsedBadgeSize,
            height: metrics.laneCollapsedBadgeSize
          )
          .background(HarnessMonitorTheme.controlBorder.opacity(0.34), in: Circle())
          .accessibilityHidden(true)

        collapsedTitle

        Spacer(minLength: 0)
      }
      .frame(
        minWidth: collapsedContentWidth,
        idealWidth: collapsedContentWidth,
        maxWidth: collapsedContentWidth,
        maxHeight: .infinity,
        alignment: .top
      )
      .padding(.horizontal, metrics.laneCollapsedInnerPadding)
      .padding(.top, collapsedButtonTopPadding)
      .padding(.bottom, metrics.laneCollapsedInnerPadding)
      .frame(
        minWidth: collapsedButtonWidth,
        idealWidth: collapsedButtonWidth,
        maxWidth: collapsedButtonWidth,
        maxHeight: .infinity,
        alignment: .top
      )
      .contentShape(Rectangle())
      .clipped()
    }
    .harnessPlainButtonStyle()
    .taskBoardLaneToggleFeedback(lane: lane, cornerRadius: metrics.cardCornerRadius)
    .help("Expand \(lane.title) board")
    .accessibilityLabel("Expand \(lane.title) board")
    .accessibilityValue("\(count) items")
  }

  private func expand() {
    collapseOverridesRawValue = TaskBoardLaneCollapsePreferences.toggledRawValue(
      lane: lane,
      contentCount: count,
      rawValue: collapseOverridesRawValue
    )
  }

  private var collapsedTitle: some View {
    Text(lane.title)
      .font(titleFont)
      .foregroundStyle(HarnessMonitorTheme.ink.opacity(0.82))
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .frame(
        width: metrics.laneCollapsedTitleHeight,
        height: metrics.laneCollapsedTextWidth,
        alignment: .leading
      )
      .rotationEffect(.degrees(90))
      .offset(y: collapsedTitleVerticalOffset)
      .frame(
        minWidth: collapsedContentWidth,
        idealWidth: collapsedContentWidth,
        maxWidth: collapsedContentWidth,
        minHeight: metrics.laneCollapsedTitleHeight,
        idealHeight: metrics.laneCollapsedTitleHeight,
        maxHeight: metrics.laneCollapsedTitleHeight,
        alignment: .top
      )
      .clipped()
  }

  private var collapsedTitleVerticalOffset: CGFloat {
    max(0, (metrics.laneCollapsedTitleHeight - metrics.laneCollapsedTextWidth) / 2)
  }
}

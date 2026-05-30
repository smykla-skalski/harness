import Foundation
import HarnessMonitorKit
import SwiftUI

struct DashboardReviewConversationCollapsedGapRailOverlay: View {
  let startRowID: String?
  let endRowID: String?
  let markerAnchors: [String: Anchor<CGRect>]

  var body: some View {
    GeometryReader { proxy in
      let markerFrames = markerAnchors.mapValues { proxy[$0] }
      if let startRowID,
        let endRowID,
        let startFrame = markerFrames[startRowID],
        let endFrame = markerFrames[endRowID]
      {
        let top = min(startFrame.midY, endFrame.midY)
        let bottom = max(startFrame.midY, endFrame.midY)
        let height = max(bottom - top, 1)
        Rectangle()
          .fill(Color(nsColor: .windowBackgroundColor))
          .frame(width: SessionTimelineLayout.railWidth, height: height)
          .overlay {
            Path { path in
              let x = SessionTimelineLayout.railWidth / 2
              path.move(to: CGPoint(x: x, y: 0))
              path.addLine(to: CGPoint(x: x, y: height))
            }
            .stroke(
              HarnessMonitorTheme.controlBorder.opacity(0.55),
              style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 5])
            )
            .frame(width: SessionTimelineLayout.railWidth, height: height)
          }
          .offset(
            x: SessionTimelineLayout.railLineOffset - (SessionTimelineLayout.railWidth / 2),
            y: top
          )
      }
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

struct DashboardReviewConversationCollapsedGapDivider: View {
  let action: DashboardReviewConversationCollapsedGapAction
  let anchorID: String
  let onAnchorMinYChange: (CGFloat) -> Void
  let fontScale: CGFloat
  let onExpand: () -> Void
  @State private var isHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Color.clear
        .frame(height: 1)
        .frame(maxWidth: .infinity)
        .id(anchorID)
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.frame(in: .named(DashboardReviewDetailScrollCoordinateSpace.name)).minY
        } action: { _, minY in
          onAnchorMinYChange(minY)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
      HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
        Color.clear
          .frame(width: SessionTimelineLayout.timeColumnWidth)
        Button(action: onExpand) {
          HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
            railSpacer
            CollapsedGapDividerLabel(
              title: action.title,
              fontScale: fontScale
            )
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, HarnessMonitorTheme.spacingXS)
        }
        .buttonStyle(
          CollapsedGapDividerButtonStyle(isHovered: isHovered)
        )
        .onHover { hovering in
          isHovered = hovering
        }
        .pointerStyle(.link)
        .help(action.helpText)
        .accessibilityLabel(action.title)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var railSpacer: some View {
    Color.clear
      .frame(width: SessionTimelineLayout.railWidth)
      .accessibilityHidden(true)
  }
}

private enum CollapsedGapDividerInteractionState {
  case resting
  case hovered
  case pressed

  var textColor: Color {
    switch self {
    case .resting:
      HarnessMonitorTheme.accent
    case .hovered:
      HarnessMonitorTheme.warmAccent.opacity(0.92)
    case .pressed:
      HarnessMonitorTheme.warmAccent
    }
  }

  var lineColor: Color {
    switch self {
    case .resting:
      HarnessMonitorTheme.controlBorder.opacity(0.42)
    case .hovered:
      HarnessMonitorTheme.warmAccent.opacity(0.92)
    case .pressed:
      HarnessMonitorTheme.warmAccent
    }
  }
}

extension EnvironmentValues {
  @Entry fileprivate var collapsedGapDividerInteractionState: CollapsedGapDividerInteractionState =
    .resting
}

private struct CollapsedGapDividerLabel: View {
  let title: String
  let fontScale: CGFloat
  @Environment(\.collapsedGapDividerInteractionState)
  private var interactionState

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      dottedLine
      Text(title)
        .font(
          HarnessMonitorTextSize.scaledFont(
            .caption.monospaced().weight(.medium),
            by: fontScale
          )
        )
        .foregroundStyle(interactionState.textColor)
      dottedLine
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private var dottedLine: some View {
    Rectangle()
      .stroke(
        interactionState.lineColor,
        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4])
      )
      .frame(height: 1)
      .accessibilityHidden(true)
  }
}

private struct CollapsedGapDividerButtonStyle: ButtonStyle {
  let isHovered: Bool

  func makeBody(configuration: Configuration) -> some View {
    let interactionState: CollapsedGapDividerInteractionState =
      if configuration.isPressed {
        .pressed
      } else if isHovered {
        .hovered
      } else {
        .resting
      }
    configuration.label
      .environment(
        \.collapsedGapDividerInteractionState,
        interactionState
      )
      .contentShape(
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
      )
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.12), value: isHovered)
  }
}

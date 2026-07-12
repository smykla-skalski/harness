import HarnessMonitorKit
import SwiftUI

struct TaskBoardLaneMetrics: Equatable {
  let laneSpacing: CGFloat
  let laneInnerPadding: CGFloat
  let laneWidth: CGFloat
  let laneCollapsedWidth: CGFloat
  let laneCollapsedInnerPadding: CGFloat
  let laneCollapsedBadgeSize: CGFloat
  let laneCollapsedTextWidth: CGFloat
  let laneCollapsedTitleHeight: CGFloat
  let laneCollapsedContentTopPadding: CGFloat
  let laneFixedHeight: CGFloat
  let laneBodyTopPadding: CGFloat
  let laneAccentHeight: CGFloat
  let laneAccentVisibleHeight: CGFloat
  let laneAccentCornerRadius: CGFloat
  let laneAccentInteriorCornerRadius: CGFloat
  let headerIconWidth: CGFloat
  let headerBottomPadding: CGFloat
  let laneHeaderBodyTopPadding: CGFloat
  let countHorizontalPadding: CGFloat
  let countVerticalPadding: CGFloat
  let emptyLaneMinHeight: CGFloat
  let cardPadding: CGFloat
  let cardCornerRadius: CGFloat
  let cardMarkerSize: CGFloat
  let cardMarkerTopPadding: CGFloat
  let rowTextSpacing: CGFloat
  let pillHorizontalPadding: CGFloat
  let pillVerticalPadding: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    let denseScale = min(scale, 1.3)
    let broadScale = min(scale, 1.16)
    let heightScale = min(scale, 1.18)
    laneSpacing = HarnessMonitorTheme.spacingSM * denseScale
    laneInnerPadding = HarnessMonitorTheme.spacingMD * denseScale
    laneWidth = 420 * broadScale
    laneCollapsedWidth = max(72, 72 * min(scale, 1.12))
    laneCollapsedInnerPadding = HarnessMonitorTheme.spacingSM * denseScale
    laneCollapsedBadgeSize = max(34, 34 * min(scale, 1.18))
    laneCollapsedTextWidth = max(28, 28 * min(scale, 1.18))
    laneCollapsedTitleHeight = max(160, 160 * min(scale, 1.18))
    laneCollapsedContentTopPadding = HarnessMonitorTheme.spacingMD * denseScale
    laneFixedHeight = 704 * heightScale
    laneBodyTopPadding = HarnessMonitorTheme.spacingSM * denseScale
    laneAccentHeight = max(8, 8 * min(scale, 1.12))
    laneAccentVisibleHeight = max(4, 4 * min(scale, 1.12))
    headerIconWidth = 18 * min(scale, 1.25)
    headerBottomPadding = HarnessMonitorTheme.spacingSM * denseScale
    laneHeaderBodyTopPadding = max(0, laneInnerPadding - headerBottomPadding)
    countHorizontalPadding = HarnessMonitorTheme.spacingSM * denseScale
    countVerticalPadding = HarnessMonitorTheme.spacingXS * min(scale, 1.2)
    emptyLaneMinHeight = 92 * heightScale
    cardPadding = HarnessMonitorTheme.spacingMD * denseScale
    cardCornerRadius = HarnessMonitorTheme.cornerRadiusSM
    laneAccentCornerRadius = min(cardCornerRadius, laneAccentHeight)
    laneAccentInteriorCornerRadius = min(cardCornerRadius, laneAccentHeight)
    cardMarkerSize = 28 * min(scale, 1.15)
    cardMarkerTopPadding = 2 * denseScale
    rowTextSpacing = HarnessMonitorTheme.spacingXS * denseScale
    pillHorizontalPadding = HarnessMonitorTheme.pillPaddingH * denseScale
    pillVerticalPadding = HarnessMonitorTheme.pillPaddingV * min(scale, 1.2)
  }
}

struct TaskBoardEmptyLane: View {
  let lane: TaskBoardInboxLane
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.taskBoardLaneAppearance)
  private var laneAppearance

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(spacing: metrics.laneSpacing) {
      if let symbolName = taskBoardLaneSystemImage(for: lane, appearance: laneAppearance) {
        TaskBoardCardLeadingIcon(
          systemImage: symbolName,
          tint: taskBoardLaneColor(for: lane, appearance: laneAppearance)
        )
      }
      Text("Nothing here")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, minHeight: metrics.emptyLaneMinHeight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(lane.title) lane empty")
  }
}

struct TaskBoardCardLeadingIcon: View {
  let systemImage: String
  let tint: Color
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var iconFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    Image(systemName: systemImage)
      .font(iconFont)
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
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var pillFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption2.weight(.bold), by: fontScale)
  }

  var body: some View {
    let pillFont = pillFont
    return HStack(spacing: HarnessMonitorTheme.spacingXS) {
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
    .padding(.horizontal, metrics.pillHorizontalPadding)
    .padding(.vertical, metrics.pillVerticalPadding)
    .harnessContentPill(tint: tint)
  }
}

struct TaskBoardCardTitleTypography {
  let font: Font
  let codeFont: Font

  init(fontScale: CGFloat) {
    font = HarnessMonitorTextSize.scaledFont(
      .subheadline.weight(.semibold),
      by: fontScale
    )
    codeFont = HarnessMonitorTextSize.scaledFont(
      .subheadline.monospaced().weight(.semibold),
      by: fontScale
    )
  }
}

struct TaskBoardCardFooter<Badges: View>: View {
  let repository: String
  let badges: Badges
  @Environment(\.fontScale)
  private var fontScale

  init(repository: String, @ViewBuilder badges: () -> Badges) {
    self.repository = repository
    self.badges = badges()
  }

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var repositoryFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: metrics.laneBodyTopPadding) {
      Text(repository)
        .font(repositoryFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .truncationMode(.middle)
        .multilineTextAlignment(.leading)
        .layoutPriority(2)
      Spacer(minLength: metrics.laneBodyTopPadding)
      HarnessMonitorWrapLayout(
        spacing: metrics.laneBodyTopPadding,
        lineSpacing: metrics.laneBodyTopPadding
      ) {
        badges
      }
      .layoutPriority(1)
    }
  }
}

enum TaskBoardLaneCardHoverID: Hashable {
  case api(String)
  case inbox(sessionID: String, taskID: String)
  case decision(String)
}

struct TaskBoardLaneCardFrame: Equatable {
  let id: TaskBoardLaneCardHoverID
  let frame: CGRect
}

struct TaskBoardLaneCardFramePreferenceKey: PreferenceKey {
  static let defaultValue: [TaskBoardLaneCardFrame] = []

  static func reduce(
    value: inout [TaskBoardLaneCardFrame],
    nextValue: () -> [TaskBoardLaneCardFrame]
  ) {
    value.append(contentsOf: nextValue())
  }
}

private struct TaskBoardCardChrome: ViewModifier {
  let tint: Color
  let isHovered: Bool
  let isSelected: Bool
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast
  @Environment(\.colorScheme)
  private var colorScheme

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  func body(content: Content) -> some View {
    content
      // Lane cards live inside a scrolling column with many siblings.
      // Keep per-card `.onHover` out of this modifier; the lane owns one
      // hover region and passes the matching row as a lightweight hint.
      .harnessInteractiveCardButtonStyle(
        cornerRadius: metrics.cardCornerRadius,
        tint: tint,
        extraHoverHint: isHovered,
        respondsToHover: false
      )
      .background {
        let shape = RoundedRectangle(
          cornerRadius: metrics.cardCornerRadius,
          style: .continuous
        )
        shape.fill(cardSurfaceFill)
        if isSelected {
          shape.fill(tint.opacity(selectedFillOpacity))
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)
          .strokeBorder(
            cardStrokeColor,
            lineWidth: cardStrokeWidth
          )
      }
  }

  private var selectedFillOpacity: Double {
    reduceTransparency ? 0.2 : 0.12
  }

  private var cardStrokeColor: Color {
    if isSelected {
      return tint.opacity(colorSchemeContrast == .increased ? 1 : 0.86)
    }
    return HarnessMonitorTheme.controlBorder.opacity(
      colorSchemeContrast == .increased ? 0.74 : 0.52
    )
  }

  private var cardStrokeWidth: CGFloat {
    isSelected ? 2 : (colorSchemeContrast == .increased ? 1.5 : 1)
  }

  private var cardSurfaceFill: Color {
    switch colorScheme {
    case .dark:
      if reduceTransparency {
        return Color(red: 0.225, green: 0.26, blue: 0.27)
      }
      return Color(red: 0.205, green: 0.24, blue: 0.25)
    default:
      if reduceTransparency {
        return Color(red: 0.98, green: 0.99, blue: 0.995)
      }
      return Color(red: 0.99, green: 0.995, blue: 1)
    }
  }
}

extension View {
  func taskBoardCardChrome(
    tint: Color = HarnessMonitorTheme.accent,
    isHovered: Bool = false,
    isSelected: Bool = false
  ) -> some View {
    modifier(
      TaskBoardCardChrome(tint: tint, isHovered: isHovered, isSelected: isSelected)
    )
  }

  func taskBoardCardFrame(
    id: TaskBoardLaneCardHoverID,
    in coordinateSpace: String
  ) -> some View {
    background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: TaskBoardLaneCardFramePreferenceKey.self,
          value: [
            TaskBoardLaneCardFrame(
              id: id,
              frame: proxy.frame(in: .named(coordinateSpace))
            )
          ]
        )
      }
    }
  }
}

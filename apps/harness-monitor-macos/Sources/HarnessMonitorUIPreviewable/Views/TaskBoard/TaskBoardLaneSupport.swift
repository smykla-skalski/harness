import HarnessMonitorKit
import SwiftUI

struct TaskBoardLaneMetrics: Equatable {
  let laneSpacing: CGFloat
  let laneInnerPadding: CGFloat
  let laneWidth: CGFloat
  let laneFixedHeight: CGFloat
  let laneBodyTopPadding: CGFloat
  let headerIconWidth: CGFloat
  let headerHorizontalPadding: CGFloat
  let headerVerticalPadding: CGFloat
  let headerBottomPadding: CGFloat
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
  let dragPreviewWidth: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    let denseScale = min(scale, 1.3)
    let broadScale = min(scale, 1.16)
    let heightScale = min(scale, 1.18)
    laneSpacing = HarnessMonitorTheme.spacingSM * denseScale
    laneInnerPadding = HarnessMonitorTheme.spacingMD * denseScale
    laneWidth = 420 * broadScale
    laneFixedHeight = 704 * heightScale
    laneBodyTopPadding = HarnessMonitorTheme.spacingSM * denseScale
    headerIconWidth = 18 * min(scale, 1.25)
    headerHorizontalPadding = 0
    headerVerticalPadding = 0
    headerBottomPadding = HarnessMonitorTheme.spacingSM * denseScale
    countHorizontalPadding = HarnessMonitorTheme.spacingSM * denseScale
    countVerticalPadding = HarnessMonitorTheme.spacingXS * min(scale, 1.2)
    emptyLaneMinHeight = 92 * heightScale
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

struct TaskBoardEmptyLane: View {
  let lane: TaskBoardInboxLane
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(spacing: metrics.laneSpacing) {
      TaskBoardCardLeadingIcon(
        systemImage: lane.systemImage,
        tint: taskBoardLaneColor(for: lane)
      )
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

private struct TaskBoardInlineCodeFragment: Equatable {
  let text: String
  let isCode: Bool
}

enum TaskBoardInlineCodeFormatter {
  static func displayText(for rawText: String) -> String {
    fragments(in: rawText).map(\.text).joined()
  }

  static func attributedText(
    for rawText: String,
    codeFont: Font,
    codeForeground: Color = HarnessMonitorTheme.ink,
    codeBackground: Color = HarnessMonitorTheme.accent.opacity(0.10)
  ) -> AttributedString {
    fragments(in: rawText).reduce(into: AttributedString()) { result, fragment in
      var attributedFragment = AttributedString(fragment.text)
      if fragment.isCode {
        attributedFragment.font = codeFont
        attributedFragment.foregroundColor = codeForeground
        attributedFragment.backgroundColor = codeBackground
      }
      result += attributedFragment
    }
  }

  private static func fragments(in rawText: String) -> [TaskBoardInlineCodeFragment] {
    guard rawText.contains("`") else {
      return [.init(text: rawText, isCode: false)]
    }

    var fragments: [TaskBoardInlineCodeFragment] = []
    var cursor = rawText.startIndex
    var index = rawText.startIndex

    while index < rawText.endIndex {
      guard rawText[index] == "`" else {
        index = rawText.index(after: index)
        continue
      }

      let afterOpen = rawText.index(after: index)
      guard
        let close = rawText[afterOpen...].firstIndex(of: "`"),
        close > afterOpen
      else {
        index = afterOpen
        continue
      }

      if cursor < index {
        fragments.append(.init(text: String(rawText[cursor..<index]), isCode: false))
      }
      fragments.append(.init(text: String(rawText[afterOpen..<close]), isCode: true))
      cursor = rawText.index(after: close)
      index = cursor
    }

    if cursor < rawText.endIndex {
      fragments.append(.init(text: String(rawText[cursor...]), isCode: false))
    }

    return fragments.isEmpty ? [.init(text: rawText, isCode: false)] : fragments
  }
}

/// Lightweight backtick-span renderer so task-board rows avoid the full markdown path.
struct TaskBoardInlineCodeText: View {
  let text: String
  let font: Font
  let codeFont: Font
  var foregroundStyle: Color = .primary
  var codeForeground: Color = HarnessMonitorTheme.ink
  var codeBackground: Color = HarnessMonitorTheme.accent.opacity(0.10)
  var lineLimit: Int?
  var truncationMode: Text.TruncationMode = .tail
  var multilineTextAlignment: TextAlignment = .leading

  init(
    _ text: String,
    font: Font,
    codeFont: Font,
    foregroundStyle: Color = .primary,
    codeForeground: Color = HarnessMonitorTheme.ink,
    codeBackground: Color = HarnessMonitorTheme.accent.opacity(0.10),
    lineLimit: Int? = nil,
    truncationMode: Text.TruncationMode = .tail,
    multilineTextAlignment: TextAlignment = .leading
  ) {
    self.text = text
    self.font = font
    self.codeFont = codeFont
    self.foregroundStyle = foregroundStyle
    self.codeForeground = codeForeground
    self.codeBackground = codeBackground
    self.lineLimit = lineLimit
    self.truncationMode = truncationMode
    self.multilineTextAlignment = multilineTextAlignment
  }

  var body: some View {
    Text(
      TaskBoardInlineCodeFormatter.attributedText(
        for: text,
        codeFont: codeFont,
        codeForeground: codeForeground,
        codeBackground: codeBackground
      )
    )
    .font(font)
    .foregroundStyle(foregroundStyle)
    .lineLimit(lineLimit)
    .truncationMode(truncationMode)
    .multilineTextAlignment(multilineTextAlignment)
    .accessibilityLabel(TaskBoardInlineCodeFormatter.displayText(for: text))
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
      HarnessMonitorWrapLayout(
        spacing: metrics.laneBodyTopPadding,
        lineSpacing: metrics.laneBodyTopPadding
      ) {
        badges
      }
      .layoutPriority(1)
      Spacer(minLength: metrics.laneBodyTopPadding)
      Text(repository)
        .font(repositoryFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .truncationMode(.middle)
        .multilineTextAlignment(.trailing)
        .layoutPriority(2)
    }
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
      // Lane cards live inside a scrolling column with many siblings;
      // attaching `.onHover` to each card produces a hover-region
      // cascade during scroll that dominates the lane-scroll hot path
      // (see r23 cause graph + InteractiveCardHoverModifier comment).
      // The press affordance from the button style is preserved.
      .harnessInteractiveCardButtonStyle(
        cornerRadius: metrics.cardCornerRadius,
        respondsToHover: false
      )
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

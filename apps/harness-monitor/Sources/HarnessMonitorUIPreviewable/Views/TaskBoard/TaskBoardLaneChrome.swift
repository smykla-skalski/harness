import HarnessMonitorKit
import SwiftUI

struct TaskBoardLaneHeader: View {
  let lane: TaskBoardInboxLane
  let count: Int
  let onToggleCollapse: () -> Void
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.taskBoardLaneAppearance)
  private var laneAppearance

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var laneColor: Color { taskBoardLaneColor(for: lane, appearance: laneAppearance) }
  private var laneSymbol: String? {
    taskBoardLaneSystemImage(for: lane, appearance: laneAppearance)
  }
  private var iconFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.title3.weight(.semibold), by: fontScale)
  }
  private var countFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.bold), by: fontScale)
  }

  var body: some View {
    Button(action: onToggleCollapse) {
      headerContent
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, metrics.laneInnerPadding)
        .padding(.top, metrics.laneInnerPadding)
        .padding(.bottom, metrics.headerBottomPadding)
        .contentShape(Rectangle())
    }
    .harnessPlainButtonStyle()
    .frame(maxWidth: .infinity, alignment: .leading)
    .taskBoardLaneToggleFeedback(lane: lane, cornerRadius: metrics.cardCornerRadius)
    .help("Collapse \(lane.title) board")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Collapse \(lane.title) board")
    .accessibilityValue("\(count) items")
    .accessibilityAddTraits(.isHeader)
  }

  private var headerContent: some View {
    HStack(spacing: metrics.laneSpacing) {
      if let laneSymbol {
        Image(systemName: laneSymbol)
          .font(iconFont)
          .foregroundStyle(laneColor)
          .frame(
            width: metrics.headerIconWidth + HarnessMonitorTheme.spacingMD,
            height: metrics.headerIconWidth + HarnessMonitorTheme.spacingMD
          )
          .background(laneColor.opacity(0.14), in: Circle())
          .accessibilityHidden(true)
      }
      Text(lane.title)
        .font(titleFont)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.78)
      Spacer(minLength: metrics.laneSpacing)
      Text("\(count)")
        .font(countFont)
        .foregroundStyle(laneColor)
        .monospacedDigit()
        .padding(.horizontal, metrics.countHorizontalPadding)
        .padding(.vertical, metrics.countVerticalPadding)
        .background(laneColor.opacity(0.14), in: .capsule)
        .overlay {
          Capsule()
            .stroke(laneColor.opacity(0.26), lineWidth: 1)
        }
    }
  }
}

private struct TaskBoardLaneToggleFeedback: ViewModifier {
  let lane: TaskBoardInboxLane
  let cornerRadius: CGFloat
  @State private var isHovered = false
  @GestureState private var isPressed = false
  @Environment(\.taskBoardLaneAppearance)
  private var laneAppearance

  private var laneColor: Color { taskBoardLaneColor(for: lane, appearance: laneAppearance) }

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(laneColor.opacity(backgroundOpacity))
      }
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(laneColor.opacity(strokeOpacity), lineWidth: 1)
      }
      .onHover { hovering in
        isHovered = hovering
      }
      .simultaneousGesture(pressGesture)
      .animation(.easeOut(duration: 0.12), value: isHovered)
      .animation(.easeOut(duration: 0.08), value: isPressed)
  }

  private var pressGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .updating($isPressed) { _, state, _ in
        state = true
      }
  }

  private var backgroundOpacity: Double {
    if isPressed {
      return 0.18
    }
    return isHovered ? 0.11 : 0
  }

  private var strokeOpacity: Double {
    if isPressed {
      return 0.34
    }
    return isHovered ? 0.22 : 0
  }
}

private struct TaskBoardLaneColumnChrome: ViewModifier {
  let lane: TaskBoardInboxLane
  let isCollapsed: Bool
  let isDropCandidate: Bool
  let isDropTargeted: Bool
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast
  @Environment(\.colorScheme)
  private var colorScheme
  @Environment(\.taskBoardLaneAppearance)
  private var laneAppearance

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var laneColor: Color { taskBoardLaneColor(for: lane, appearance: laneAppearance) }

  func body(content: Content) -> some View {
    content
      .frame(
        minWidth: laneWidth,
        idealWidth: laneWidth,
        maxWidth: laneMaxWidth,
        minHeight: metrics.laneFixedHeight,
        idealHeight: metrics.laneFixedHeight,
        maxHeight: .infinity,
        alignment: .topLeading
      )
      .background {
        laneBackground
      }
      .overlay {
        RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)
          .strokeBorder(laneStrokeColor, lineWidth: laneStrokeWidth)
      }
      .overlay(alignment: .top) {
        TaskBoardLaneAccentCap(
          color: laneAccentColor,
          interiorStyle: laneAccentInteriorStyle,
          punchesInteriorThrough: true,
          metrics: metrics
        )
      }
      .animation(.easeOut(duration: 0.14), value: isDropCandidate)
      .animation(.easeOut(duration: 0.1), value: isDropTargeted)
  }

  private var laneWidth: CGFloat {
    isCollapsed ? metrics.laneCollapsedWidth : metrics.laneWidth
  }

  private var laneMaxWidth: CGFloat {
    isCollapsed ? metrics.laneCollapsedWidth : .infinity
  }

  @ViewBuilder private var laneBackground: some View {
    let shape = RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)
    shape.fill(laneSurfaceFill)
    if isDropCandidate {
      shape.fill(laneColor.opacity(dropBackgroundOpacity))
    }
  }

  private var dropBackgroundOpacity: Double {
    if isDropTargeted {
      return reduceTransparency ? 0.18 : 0.12
    }
    return reduceTransparency ? 0.1 : 0.055
  }

  private var laneSurfaceFill: Color {
    switch colorScheme {
    case .dark:
      if reduceTransparency {
        return Color(red: 0.19, green: 0.225, blue: 0.235)
      }
      return Color(red: 0.155, green: 0.19, blue: 0.2)
    default:
      if reduceTransparency {
        return Color(red: 0.9, green: 0.925, blue: 0.94)
      }
      return Color(red: 0.925, green: 0.945, blue: 0.955)
    }
  }

  private var laneAccentInteriorStyle: AnyShapeStyle {
    AnyShapeStyle(laneSurfaceFill)
  }

  private var laneStrokeColor: Color {
    if isDropTargeted {
      return laneColor.opacity(colorSchemeContrast == .increased ? 0.84 : 0.62)
    }
    if isDropCandidate {
      return laneColor.opacity(colorSchemeContrast == .increased ? 0.64 : 0.42)
    }
    return HarnessMonitorTheme.controlBorder.opacity(
      colorSchemeContrast == .increased ? 0.78 : 0.54
    )
  }

  private var laneAccentColor: Color {
    if isDropTargeted {
      return laneColor.opacity(colorSchemeContrast == .increased ? 1 : 0.96)
    }
    return laneColor.opacity(colorSchemeContrast == .increased ? 0.96 : 0.9)
  }

  private var laneStrokeWidth: CGFloat {
    colorSchemeContrast == .increased ? 2 : 1
  }
}

private struct TaskBoardLaneAccentCap: View {
  let color: Color
  let interiorStyle: AnyShapeStyle
  let punchesInteriorThrough: Bool
  let metrics: TaskBoardLaneMetrics

  var body: some View {
    ZStack(alignment: .top) {
      if punchesInteriorThrough {
        TaskBoardLanePunchedAccentShape(
          cornerRadius: metrics.laneAccentCornerRadius,
          interiorCornerRadius: metrics.laneAccentInteriorCornerRadius,
          interiorOffset: metrics.laneAccentVisibleHeight
        )
        .fill(color, style: FillStyle(eoFill: true))
      } else {
        TaskBoardLaneTopRoundedShape(cornerRadius: metrics.laneAccentCornerRadius)
          .fill(color)
        TaskBoardLaneTopRoundedShape(cornerRadius: metrics.laneAccentInteriorCornerRadius)
          .fill(interiorStyle)
          .frame(height: metrics.laneAccentHeight)
          .offset(y: metrics.laneAccentVisibleHeight)
      }
    }
    .frame(height: metrics.laneAccentHeight)
    .clipped()
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

private struct TaskBoardLanePunchedAccentShape: Shape {
  let cornerRadius: CGFloat
  let interiorCornerRadius: CGFloat
  let interiorOffset: CGFloat

  func path(in rect: CGRect) -> Path {
    var path = TaskBoardLaneTopRoundedShape(cornerRadius: cornerRadius).path(in: rect)
    let interiorRect = rect.offsetBy(dx: 0, dy: interiorOffset)
    path.addPath(
      TaskBoardLaneTopRoundedShape(cornerRadius: interiorCornerRadius)
        .path(in: interiorRect)
    )
    return path
  }
}

private struct TaskBoardLaneTopRoundedShape: Shape {
  let cornerRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    let radius = min(cornerRadius, rect.width / 2, rect.height)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.minY),
      control: CGPoint(x: rect.minX, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + radius),
      control: CGPoint(x: rect.maxX, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

private struct TaskBoardLaneBodyChrome: ViewModifier {
  let lane: TaskBoardInboxLane
  let isDropTargeted: Bool
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.taskBoardLaneAppearance)
  private var laneAppearance

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var laneColor: Color { taskBoardLaneColor(for: lane, appearance: laneAppearance) }

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.top, metrics.laneHeaderBodyTopPadding)
      .background {
        if isDropTargeted {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
            .fill(
              laneColor.opacity(reduceTransparency ? 0.14 : 0.08)
            )
        }
      }
  }
}

extension View {
  func taskBoardLaneToggleFeedback(
    lane: TaskBoardInboxLane,
    cornerRadius: CGFloat
  ) -> some View {
    modifier(TaskBoardLaneToggleFeedback(lane: lane, cornerRadius: cornerRadius))
  }

  func taskBoardLaneColumnChrome(
    lane: TaskBoardInboxLane,
    isCollapsed: Bool = false,
    isDropCandidate: Bool = false,
    isDropTargeted: Bool = false
  ) -> some View {
    modifier(
      TaskBoardLaneColumnChrome(
        lane: lane,
        isCollapsed: isCollapsed,
        isDropCandidate: isDropCandidate,
        isDropTargeted: isDropTargeted
      )
    )
  }

  func taskBoardLaneBodyChrome(
    lane: TaskBoardInboxLane,
    isDropTargeted: Bool = false
  ) -> some View {
    modifier(TaskBoardLaneBodyChrome(lane: lane, isDropTargeted: isDropTargeted))
  }
}

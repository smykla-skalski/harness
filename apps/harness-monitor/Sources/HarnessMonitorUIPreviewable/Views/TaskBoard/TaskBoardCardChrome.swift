import SwiftUI

struct TaskBoardCardUpdatedAtLabel: View {
  let updatedAt: Date?
  let font: Font
  @Environment(TaskBoardRelativeTimeClock.self)
  private var relativeTimeClock

  var body: some View {
    let referenceDate = relativeTimeClock.referenceDate
    let label = formatCompactRelativeUpdatedAt(
      updatedAt,
      reference: referenceDate
    )
    if !label.isEmpty {
      let accessibleAge =
        label == "just now"
        ? label
        : formatRelativeUpdatedAt(updatedAt, reference: referenceDate)
      Text(label)
        .font(font)
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk.opacity(0.8))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Updated \(accessibleAge)")
        .harnessOpticalTextCenter()
    }
  }
}

enum TaskBoardLaneCardHoverID: Hashable {
  case api(String)
  case inbox(sessionID: String, taskID: String)
  case decision(String)
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
          .allowsHitTesting(false)
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
    taskBoardCardSurfaceFill(colorScheme: colorScheme, reduceTransparency: reduceTransparency)
  }
}

/// Shared so anything that has to sit level with a card - the lane's quick-add
/// field, for one - reads the same surface rather than a second copy of it.
func taskBoardCardSurfaceFill(colorScheme: ColorScheme, reduceTransparency: Bool) -> Color {
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

  /// Each card reports its frame directly instead of reducing one shared
  /// preference. Geometry publication pauses while the list scrolls; the lane
  /// clears old frames at scroll start and visible rows publish current frames
  /// when scrolling settles.
  func taskBoardCardFrame(
    id: TaskBoardLaneCardHoverID,
    in coordinateSpace: String,
    tracking: TaskBoardLaneHoverTracking,
    behavior: TaskBoardCardFrameBehavior,
    onChange: @escaping () -> Void
  ) -> some View {
    onGeometryChange(for: CGRect?.self) { proxy in
      behavior.isGeometryRecordingEnabled ? proxy.frame(in: .named(coordinateSpace)) : nil
    } action: { frame in
      guard let frame else { return }
      TaskBoardCardDragDiagnostics.recordGeometryUpdate()
      tracking.setFrame(frame, for: id)
      guard let location = tracking.location else { return }
      if behavior.isHovered || frame.contains(location) { onChange() }
    }
    .onDisappear {
      tracking.removeFrame(for: id)
      if behavior.isHovered { onChange() }
    }
  }
}

struct TaskBoardCardFrameBehavior: Sendable {
  let isHovered: Bool
  let isGeometryRecordingEnabled: Bool
}

import AppKit
import SwiftUI

enum SessionContentDetailSplitLayout {
  static let dividerWidth: CGFloat = 1
  static let defaultContentWidth: Double = 440
  static let minimumContentWidth: CGFloat = 280
  static let minimumDetailWidth: CGFloat = 320
  static let minimumVisibleColumnWidth: CGFloat = 220
  static let keyboardAdjustmentStep: Double = 40

  static func contentWidthRange(availableWidth: CGFloat) -> ClosedRange<Double> {
    let safeAvailable =
      max(
        availableWidth - dividerWidth,
        (minimumVisibleColumnWidth * 2) + dividerWidth
      )
    let resolvedMinimumDetailWidth =
      min(minimumDetailWidth, safeAvailable - minimumVisibleColumnWidth)
    let resolvedMinimumContentWidth =
      max(
        minimumVisibleColumnWidth,
        min(minimumContentWidth, safeAvailable - resolvedMinimumDetailWidth)
      )
    let resolvedMaximumContentWidth =
      max(resolvedMinimumContentWidth, safeAvailable - resolvedMinimumDetailWidth)

    return Double(resolvedMinimumContentWidth)...Double(resolvedMaximumContentWidth)
  }

  static func clampedContentWidth(
    preferredWidth: Double,
    availableWidth: CGFloat
  ) -> Double {
    let range = contentWidthRange(availableWidth: availableWidth)
    return min(max(preferredWidth, range.lowerBound), range.upperBound)
  }
}

struct SessionContentDetailSplitView<Content: View, Detail: View>: View {
  @Binding private var contentWidth: Double
  @State private var liveContentWidth = SessionContentDetailSplitLayout.defaultContentWidth
  @State private var isDragging = false
  private let content: Content
  private let detail: Detail

  init(
    contentWidth: Binding<Double>,
    @ViewBuilder content: () -> Content,
    @ViewBuilder detail: () -> Detail
  ) {
    _contentWidth = contentWidth
    _liveContentWidth = State(wrappedValue: contentWidth.wrappedValue)
    self.content = content()
    self.detail = detail()
  }

  var body: some View {
    GeometryReader { geometry in
      let resolvedContentWidth = SessionContentDetailSplitLayout.clampedContentWidth(
        preferredWidth: liveContentWidth,
        availableWidth: geometry.size.width
      )
      let contentRange = SessionContentDetailSplitLayout.contentWidthRange(
        availableWidth: geometry.size.width
      )

      HStack(spacing: 0) {
        content
          .frame(width: resolvedContentWidth)
          .frame(maxHeight: .infinity, alignment: .topLeading)

        SessionContentDetailDivider(
          contentWidth: $liveContentWidth,
          isDragging: $isDragging,
          widthRange: contentRange
        )

        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .onChange(of: geometry.size.width, initial: true) { _, newWidth in
        deferReclampLiveWidth(availableWidth: newWidth)
      }
      .onChange(of: liveContentWidth) { _, newValue in
        guard !isDragging else { return }
        commitPersistedWidth(newValue)
      }
      .onChange(of: isDragging) { _, dragging in
        guard !dragging else { return }
        commitPersistedWidth(liveContentWidth)
      }
    }
  }

  private func deferReclampLiveWidth(availableWidth: CGFloat) {
    // Re-clamp on the next main-actor turn so startup geometry changes do not
    // write width state back into the same frame.
    Task { @MainActor in
      await Task.yield()
      reclampLiveWidth(availableWidth: availableWidth)
    }
  }

  // No `onChange(of: contentWidth)` writer: paired listeners on the two widths
  // ping-ponged into the SwiftUI multi-update-per-frame fault on window resize.
  private func reclampLiveWidth(availableWidth: CGFloat) {
    let clamped = SessionContentDetailSplitLayout.clampedContentWidth(
      preferredWidth: liveContentWidth,
      availableWidth: availableWidth
    )
    if abs(liveContentWidth - clamped) > 0.5 {
      liveContentWidth = clamped
    }
    guard !isDragging else { return }
    commitPersistedWidth(clamped)
  }

  private func commitPersistedWidth(_ resolvedContentWidth: Double) {
    guard abs(contentWidth - resolvedContentWidth) > 0.5 else { return }
    contentWidth = resolvedContentWidth
  }
}

private struct SessionContentDetailDivider: View {
  @Binding var contentWidth: Double
  @Binding var isDragging: Bool
  let widthRange: ClosedRange<Double>
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @FocusState private var isKeyboardFocused: Bool
  @ScaledMetric(relativeTo: .body)
  private var interactiveWidth = 24.0
  @ScaledMetric(relativeTo: .body)
  private var handleHeight = 44.0
  @State private var dragStartWidth: Double?
  @State private var isHovered = false
  @State private var cursorActive = false

  var body: some View {
    Color.clear
      .frame(width: SessionContentDetailSplitLayout.dividerWidth)
      .overlay(alignment: .center) {
        Rectangle()
          .fill(separatorTint)
          .frame(width: separatorLineWidth)
      }
      .overlay(alignment: .center) {
        interactiveSurface
      }
      .onDisappear {
        updateCursor(active: false)
      }
  }

  private var focusTint: Color {
    Color(nsColor: .keyboardFocusIndicatorColor)
  }

  private var separatorTint: Color {
    if isKeyboardFocused {
      return focusTint.opacity(0.92)
    }
    if isHovered || isDragging {
      return Color(nsColor: .separatorColor).opacity(0.9)
    }
    return Color(nsColor: .separatorColor).opacity(0.68)
  }

  private var separatorLineWidth: CGFloat {
    if isKeyboardFocused {
      return 3
    }
    if isHovered || isDragging {
      return 2
    }
    return SessionContentDetailSplitLayout.dividerWidth
  }

  private var handleWidth: CGFloat {
    if isKeyboardFocused {
      return 5
    }
    if isHovered || isDragging {
      return 4
    }
    return 3
  }

  private var resolvedHandleHeight: CGFloat {
    if isKeyboardFocused || isHovered || isDragging {
      return handleHeight + 4
    }
    return handleHeight
  }

  private var animationDuration: Double {
    reduceMotion ? 0.01 : 0.12
  }

  private var dividerValue: String {
    "Content width \(Int(contentWidth.rounded())) points"
  }

  private var interactiveSurface: some View {
    ZStack {
      Rectangle()
        .fill(.clear)

      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(isKeyboardFocused ? focusTint : separatorTint)
        .frame(width: handleWidth, height: resolvedHandleHeight)
        .opacity(isKeyboardFocused || isHovered || isDragging ? 1 : 0)
    }
    .frame(width: interactiveWidth)
    .contentShape(Rectangle())
    .focusable(interactions: .activate)
    .focusEffectDisabled()
    .focused($isKeyboardFocused)
    .help("Drag or use the arrow keys to resize the content and detail panes.")
    .gesture(dragGesture)
    .onHover { isHovering in
      isHovered = isHovering
      updateCursor(active: isHovering || isDragging)
    }
    .onMoveCommand(perform: handleMoveCommand)
    .accessibilityElement()
    .accessibilityLabel("Content and detail divider")
    .accessibilityHint("Drag left or right to resize the content and detail panes")
    .accessibilityValue(dividerValue)
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        adjustContentWidth(by: SessionContentDetailSplitLayout.keyboardAdjustmentStep)
      case .decrement:
        adjustContentWidth(by: -SessionContentDetailSplitLayout.keyboardAdjustmentStep)
      @unknown default:
        break
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowContentDetailDivider)
    .accessibilityFrameMarker(
      "\(HarnessMonitorAccessibility.sessionWindowContentDetailDivider).frame"
    )
    .animation(.easeOut(duration: animationDuration), value: isHovered)
    .animation(.easeOut(duration: animationDuration), value: isDragging)
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .global)
      .onChanged { value in
        if dragStartWidth == nil {
          dragStartWidth = contentWidth
        }
        if !isDragging {
          isDragging = true
        }
        updateCursor(active: true)
        let next = (dragStartWidth ?? contentWidth) + value.translation.width
        contentWidth = min(max(next, widthRange.lowerBound), widthRange.upperBound)
      }
      .onEnded { _ in
        dragStartWidth = nil
        isDragging = false
        updateCursor(active: isHovered)
      }
  }

  private func handleMoveCommand(_ direction: MoveCommandDirection) {
    switch direction {
    case .left:
      adjustContentWidth(by: -SessionContentDetailSplitLayout.keyboardAdjustmentStep)
    case .right:
      adjustContentWidth(by: SessionContentDetailSplitLayout.keyboardAdjustmentStep)
    default:
      break
    }
  }

  private func adjustContentWidth(by delta: Double) {
    let next = contentWidth + delta
    contentWidth = min(max(next, widthRange.lowerBound), widthRange.upperBound)
  }

  private func updateCursor(active: Bool) {
    guard cursorActive != active else { return }
    cursorActive = active
    if active {
      NSCursor.resizeLeftRight.push()
    } else {
      NSCursor.pop()
    }
  }
}

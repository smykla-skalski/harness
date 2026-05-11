import AppKit
import OSLog
import SwiftUI

private let sessionContentDetailResizeSignposter = OSSignposter(
  subsystem: "io.harnessmonitor",
  category: "perf/session-content-detail-resize"
)

enum SessionContentDetailSplitLayout {
  static let dividerWidth: CGFloat = 1
  static let defaultContentWidth: Double = 440
  static let minimumContentWidth: CGFloat = 280
  static let minimumDetailWidth: CGFloat = 320
  static let minimumVisibleColumnWidth: CGFloat = 220
  static let keyboardAdjustmentStep: Double = 40
  static let dragWidthStep: Double = 2
  static let widthChangeTolerance: Double = 0.5
  static let resizeSettleDelay: Duration = .milliseconds(120)

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
  @State private var resizeState = SessionContentDetailResizeState()
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
      .transaction { transaction in
        if isDragging {
          transaction.animation = nil
        }
      }
      .onChange(of: geometry.size.width, initial: true) { _, newWidth in
        scheduleSettledGeometryReclamp(availableWidth: newWidth)
      }
      .onChange(of: liveContentWidth) { _, newValue in
        guard !isDragging else { return }
        _ = commitPersistedWidth(newValue)
      }
      .onChange(of: isDragging) { _, dragging in
        if dragging {
          resizeState.cancelPending()
          return
        }
        _ = commitPersistedWidth(liveContentWidth)
      }
      .onDisappear {
        resizeState.cancelPending()
      }
    }
  }

  private func scheduleSettledGeometryReclamp(availableWidth: CGFloat) {
    let clamped = SessionContentDetailSplitLayout.clampedContentWidth(
      preferredWidth: liveContentWidth,
      availableWidth: availableWidth
    )
    guard abs(liveContentWidth - clamped) > SessionContentDetailSplitLayout.widthChangeTolerance
    else {
      resizeState.cancelPending()
      return
    }
    resizeState.cancelPending()
    resizeState.settleTask = Task { @MainActor in
      try? await Task.sleep(for: SessionContentDetailSplitLayout.resizeSettleDelay)
      guard !Task.isCancelled else { return }
      applySettledGeometryReclamp(availableWidth: availableWidth)
      resizeState.settleTask = nil
    }
  }

  // Keep live drag updates immediate, but settle geometry-driven persistence so
  // a window resize does not write width state back into the hierarchy every frame.
  private func applySettledGeometryReclamp(availableWidth: CGFloat) {
    guard !isDragging else { return }
    let signpostID = sessionContentDetailResizeSignposter.makeSignpostID()
    let interval = sessionContentDetailResizeSignposter.beginInterval(
      "session_content_detail_resize.settle",
      id: signpostID,
      "availableWidth=\(Int(availableWidth.rounded()), privacy: .public)"
    )
    var adjustedLiveWidth = false
    var committedPersistedWidth = false
    defer {
      sessionContentDetailResizeSignposter.endInterval(
        "session_content_detail_resize.settle",
        interval,
        "adjusted=\(adjustedLiveWidth ? 1 : 0, privacy: .public) persisted=\(committedPersistedWidth ? 1 : 0, privacy: .public)"
      )
    }
    let clamped = SessionContentDetailSplitLayout.clampedContentWidth(
      preferredWidth: liveContentWidth,
      availableWidth: availableWidth
    )
    if abs(liveContentWidth - clamped) > SessionContentDetailSplitLayout.widthChangeTolerance {
      liveContentWidth = clamped
      adjustedLiveWidth = true
    }
    committedPersistedWidth = commitPersistedWidth(clamped)
  }

  private func commitPersistedWidth(_ resolvedContentWidth: Double) -> Bool {
    guard
      abs(contentWidth - resolvedContentWidth)
        > SessionContentDetailSplitLayout.widthChangeTolerance
    else {
      return false
    }
    contentWidth = resolvedContentWidth
    return true
  }
}

@MainActor
private final class SessionContentDetailResizeState {
  nonisolated(unsafe) var settleTask: Task<Void, Never>?

  deinit {
    settleTask?.cancel()
    settleTask = nil
  }

  func cancelPending() {
    settleTask?.cancel()
    settleTask = nil
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
      // The widened hit target extends beyond the 1pt divider line. Keep the
      // divider subtree above both neighboring panes so dragging works on both
      // sides of the visual separator, not just over the leading pane.
      .zIndex(1)
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
    // Keep pointer-down available for the drag gesture instead of treating the
    // divider like an activating control.
    .focusable()
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
        updateContentWidth(for: value, quantized: true)
      }
      .onEnded { value in
        updateContentWidth(for: value, quantized: false)
        dragStartWidth = nil
        isDragging = false
        updateCursor(active: isHovered)
      }
  }

  private func updateContentWidth(for value: DragGesture.Value, quantized: Bool) {
    let startWidth = dragStartWidth ?? contentWidth
    let rawWidth = min(
      max(startWidth + value.translation.width, widthRange.lowerBound),
      widthRange.upperBound
    )
    let nextWidth =
      if quantized {
        (rawWidth / SessionContentDetailSplitLayout.dragWidthStep).rounded()
          * SessionContentDetailSplitLayout.dragWidthStep
      } else {
        rawWidth
      }
    guard abs(contentWidth - nextWidth) >= SessionContentDetailSplitLayout.dragWidthStep / 2
    else {
      return
    }
    contentWidth = nextWidth
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

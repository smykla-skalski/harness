import AppKit
import SwiftUI

enum SessionContentDetailSplitLayout {
  static let dividerWidth: CGFloat = 1
  static let defaultContentWidth: Double = 440
  static let minimumContentWidth: CGFloat = 280
  static let minimumDetailWidth: CGFloat = 320
  static let minimumVisibleColumnWidth: CGFloat = 220
  static let keyboardAdjustmentStep: Double = 40
  static let dragWidthStep: Double = 2

  static func contentWidthRange(availableWidth: CGFloat) -> ClosedRange<Double> {
    let safeAvailable = max(availableWidth - dividerWidth, 0)
    guard safeAvailable > 0 else {
      return 0...0
    }
    if safeAvailable < minimumVisibleColumnWidth * 2 {
      let balancedWidth = Double(safeAvailable / 2)
      return balancedWidth...balancedWidth
    }
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

@MainActor
enum SessionGeometryWritebackDeferral {
  static func nextMainActorTurn() async {
    await Task.yield()
  }
}

struct SessionContentDetailSplitView<Content: View, Detail: View, Footer: View>: View {
  @Binding private var contentWidth: Double
  @Binding private var perfOverrideContentWidth: Double?
  @State private var liveContentWidth = SessionContentDetailSplitLayout.defaultContentWidth
  @State private var isDragging = false
  private let commitContentWidth: (Double) -> Void
  private let dividerAccessibilityIdentifier: String
  private let showsDividerLine: Bool
  private let showsContentPane: Bool
  private let content: Content
  private let detail: Detail
  private let footer: Footer

  init(
    contentWidth: Binding<Double>,
    perfOverrideContentWidth: Binding<Double?> = .constant(nil),
    commitContentWidth: @escaping (Double) -> Void,
    dividerAccessibilityIdentifier: String = HarnessMonitorAccessibility
      .sessionWindowContentDetailDivider,
    showsDividerLine: Bool = true,
    @ViewBuilder content: () -> Content,
    @ViewBuilder detail: () -> Detail,
    @ViewBuilder footer: () -> Footer = { EmptyView() }
  ) {
    _contentWidth = contentWidth
    _perfOverrideContentWidth = perfOverrideContentWidth
    _liveContentWidth = State(wrappedValue: contentWidth.wrappedValue)
    self.commitContentWidth = commitContentWidth
    self.dividerAccessibilityIdentifier = dividerAccessibilityIdentifier
    self.showsDividerLine = showsDividerLine
    self.showsContentPane = true
    self.content = content()
    self.detail = detail()
    self.footer = footer()
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsContentPane {
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
              commitContentWidth: commitContentWidth,
              widthRange: contentRange,
              accessibilityIdentifier: dividerAccessibilityIdentifier,
              showsDividerLine: showsDividerLine
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
          .onChange(of: perfOverrideContentWidth, initial: true) { _, newWidth in
            syncLiveWidth(
              preferredWidth: newWidth ?? contentWidth,
              availableWidth: geometry.size.width
            )
          }
          .onChange(of: contentWidth) { _, newWidth in
            guard !isDragging, perfOverrideContentWidth == nil else { return }
            syncLiveWidth(
              preferredWidth: newWidth,
              availableWidth: geometry.size.width
            )
          }
          .onChange(of: geometry.size.width, initial: true) { _, newWidth in
            deferReclampLiveWidth(availableWidth: newWidth)
          }
        }
      } else {
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }

      footer
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func deferReclampLiveWidth(availableWidth: CGFloat) {
    // Re-clamp on the next main-actor turn so startup geometry changes do not
    // write width state back into the same frame.
    Task { @MainActor in
      await SessionGeometryWritebackDeferral.nextMainActorTurn()
      reclampLiveWidth(availableWidth: availableWidth)
    }
  }

  // No `onChange(of: contentWidth)` writer: paired listeners on the two widths
  // ping-ponged into the SwiftUI multi-update-per-frame fault on window resize.
  private func reclampLiveWidth(availableWidth: CGFloat) {
    syncLiveWidth(
      preferredWidth: perfOverrideContentWidth ?? contentWidth,
      availableWidth: availableWidth
    )
  }

  private func syncLiveWidth(
    preferredWidth: Double,
    availableWidth: CGFloat
  ) {
    let clamped = SessionContentDetailSplitLayout.clampedContentWidth(
      preferredWidth: preferredWidth,
      availableWidth: availableWidth
    )
    if abs(liveContentWidth - clamped) > 0.5 {
      liveContentWidth = clamped
    }
  }
}

extension SessionContentDetailSplitView where Content == EmptyView {
  init(
    @ViewBuilder detail: () -> Detail,
    @ViewBuilder footer: () -> Footer = { EmptyView() }
  ) {
    _contentWidth = .constant(SessionContentDetailSplitLayout.defaultContentWidth)
    _perfOverrideContentWidth = .constant(nil)
    _liveContentWidth = State(wrappedValue: SessionContentDetailSplitLayout.defaultContentWidth)
    self.commitContentWidth = { _ in }
    self.dividerAccessibilityIdentifier = HarnessMonitorAccessibility
      .sessionWindowContentDetailDivider
    self.showsDividerLine = false
    self.showsContentPane = false
    self.content = EmptyView()
    self.detail = detail()
    self.footer = footer()
  }
}

private struct SessionContentDetailDivider: View {
  @Binding var contentWidth: Double
  @Binding var isDragging: Bool
  let commitContentWidth: (Double) -> Void
  let widthRange: ClosedRange<Double>
  let accessibilityIdentifier: String
  let showsDividerLine: Bool
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
    if !showsDividerLine, !isKeyboardFocused, !isHovered, !isDragging {
      return .clear
    }
    if isKeyboardFocused {
      return focusTint.opacity(0.92)
    }
    if isHovered || isDragging {
      return Color(nsColor: .separatorColor).opacity(0.78)
    }
    return Color(nsColor: .separatorColor).opacity(0.38)
  }

  private var separatorLineWidth: CGFloat {
    if !showsDividerLine, !isKeyboardFocused, !isHovered, !isDragging {
      return 0
    }
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
    .focused($isKeyboardFocused)
    .help("Drag or use the arrow keys to resize the content and detail panes")
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
    .accessibilityIdentifier(accessibilityIdentifier)
    .accessibilityFrameMarker(
      "\(accessibilityIdentifier).frame"
    )
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
        commitContentWidth(contentWidth)
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
    commitContentWidth(contentWidth)
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

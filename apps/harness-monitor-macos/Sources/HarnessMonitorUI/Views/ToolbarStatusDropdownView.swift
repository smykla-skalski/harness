import SwiftUI

struct ToolbarStatusDropdown: View {
  let messages: [ToolbarStatusMessage]
  @State private var isHovered = false
  @State private var isPressed = false
  private static let contentHorizontalInset: CGFloat = 16

  private var highlightOpacity: Double {
    isPressed ? 0.12 : isHovered ? 0.08 : 0
  }

  var body: some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      ToolbarStatusTickerView(messages: messages, direction: .up)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.toolbarStatusTickerContentFrame)
    .padding(.horizontal, Self.contentHorizontalInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      Capsule()
        .fill(Color.primary.opacity(highlightOpacity))
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.1), value: isPressed)
    }
    .overlay {
      ToolbarStatusMenuHitArea(messages: messages, isHovered: $isHovered, isPressed: $isPressed)
    }
    .overlay {
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityFrameMarker(HarnessMonitorAccessibility.toolbarStatusTickerHoverFrame)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolbarStatusTicker)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Shows status details")
  }
}

struct ToolbarStatusMenuHitArea: NSViewRepresentable {
  let messages: [ToolbarStatusMessage]
  @Binding var isHovered: Bool
  @Binding var isPressed: Bool

  func makeNSView(context: Context) -> ToolbarStatusMenuNSView {
    let view = ToolbarStatusMenuNSView()
    view.messages = messages
    let hoverBinding = $isHovered
    let pressBinding = $isPressed
    view.onHoverChanged = { hoverBinding.wrappedValue = $0 }
    view.onPressChanged = { pressBinding.wrappedValue = $0 }
    view.setAccessibilityIdentifier(HarnessMonitorAccessibility.toolbarStatusTicker)
    view.setAccessibilityRole(.popUpButton)
    view.setAccessibilityLabel("Status messages")
    return view
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: ToolbarStatusMenuNSView,
    context: Context
  ) -> CGSize? {
    CGSize(
      width: proposal.width ?? 0,
      height: proposal.height ?? 0
    )
  }

  func updateNSView(_ nsView: ToolbarStatusMenuNSView, context: Context) {
    nsView.messages = messages
    let hoverBinding = $isHovered
    let pressBinding = $isPressed
    nsView.onHoverChanged = { hoverBinding.wrappedValue = $0 }
    nsView.onPressChanged = { pressBinding.wrappedValue = $0 }
  }
}

final class ToolbarStatusMenuNSView: NSView {
  var messages: [ToolbarStatusMessage] = []
  var onHoverChanged: ((Bool) -> Void)?
  var onPressChanged: ((Bool) -> Void)?
  private var currentTrackingArea: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    focusRingType = .exterior
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("Not supported")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override var acceptsFirstResponder: Bool { true }

  override func drawFocusRingMask() {
    let radius = bounds.height / 2
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
  }

  override var focusRingMaskBounds: NSRect { bounds }

  override func updateTrackingAreas() {
    if let existing = currentTrackingArea {
      removeTrackingArea(existing)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInActiveApp],
      owner: self
    )
    addTrackingArea(area)
    currentTrackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    onHoverChanged?(true)
    NSCursor.pointingHand.push()
  }

  override func mouseExited(with event: NSEvent) {
    onHoverChanged?(false)
    NSCursor.pop()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 49:
      showStatusMenu()
    default:
      super.keyDown(with: event)
    }
  }

  override func mouseDown(with event: NSEvent) {
    onPressChanged?(true)
    showStatusMenu()
    onPressChanged?(false)
  }

  override func accessibilityPerformPress() -> Bool {
    showStatusMenu()
    return true
  }

  func showStatusMenu() {
    let menu = NSMenu()
    for message in messages {
      let item = NSMenuItem(
        title: message.text,
        action: #selector(statusItemTapped(_:)),
        keyEquivalent: ""
      )
      item.target = self
      if let systemImage = message.systemImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configuredImage =
          NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
          .withSymbolConfiguration(config)
        if let image = configuredImage {
          item.image = image
        }
      }
      menu.addItem(item)
    }
    let point = NSPoint(x: 0, y: bounds.height)
    menu.popUp(positioning: nil, at: point, in: self)
  }

  @objc
  private func statusItemTapped(_ sender: NSMenuItem) {}
}

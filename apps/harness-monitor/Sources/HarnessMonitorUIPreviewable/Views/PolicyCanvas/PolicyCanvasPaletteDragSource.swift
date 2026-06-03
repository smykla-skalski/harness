import AppKit
import SwiftUI

struct PolicyCanvasPaletteDragSource: NSViewRepresentable {
  let payload: String
  let previewTitle: String
  let previewSymbolName: String
  let activate: @MainActor () -> Void
  let setHovering: @MainActor (Bool) -> Void

  func makeNSView(context _: Context) -> PolicyCanvasPaletteDragSourceView {
    let view = PolicyCanvasPaletteDragSourceView()
    view.setAccessibilityElement(false)
    return view
  }

  func updateNSView(_ view: PolicyCanvasPaletteDragSourceView, context _: Context) {
    view.payload = payload
    view.previewTitle = previewTitle
    view.previewSymbolName = previewSymbolName
    view.activate = activate
    view.setHovering = setHovering
  }
}

func policyCanvasPalettePasteboardItem(payload: String) -> NSPasteboardItem {
  let item = NSPasteboardItem()
  for pasteboardType in policyCanvasAcceptedTextPasteboardTypes {
    item.setString(payload, forType: pasteboardType)
  }
  return item
}

@MainActor
final class PolicyCanvasPaletteDragSourceView: NSView, NSDraggingSource {
  private enum Constants {
    static let dragThreshold = 3.0
    static let previewHeight = 34.0
    static let previewHorizontalPadding = 12.0
    static let previewIconWidth = 24.0
    static let previewSpacing = 8.0
    static let previewMaxWidth = 220.0
  }

  var payload = ""
  var previewTitle = ""
  var previewSymbolName = ""
  var activate: @MainActor () -> Void = {}
  var setHovering: @MainActor (Bool) -> Void = { _ in }

  private var mouseDownEvent: NSEvent?
  private var dragStarted = false

  override var mouseDownCanMoveWindow: Bool {
    false
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
        owner: self
      )
    )
  }

  override func mouseEntered(with _: NSEvent) {
    setHovering(true)
  }

  override func mouseExited(with _: NSEvent) {
    setHovering(false)
  }

  override func mouseDown(with event: NSEvent) {
    mouseDownEvent = event
    dragStarted = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard !dragStarted, let startEvent = mouseDownEvent, hasMovedEnough(from: startEvent, to: event)
    else {
      return
    }
    dragStarted = true
    beginPaletteDrag(with: startEvent)
  }

  override func mouseUp(with _: NSEvent) {
    defer {
      mouseDownEvent = nil
      dragStarted = false
    }
    guard !dragStarted else {
      return
    }
    activate()
  }

  func draggingSession(
    _: NSDraggingSession,
    sourceOperationMaskFor _: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  func ignoreModifierKeys(for _: NSDraggingSession) -> Bool {
    true
  }

  private func hasMovedEnough(from startEvent: NSEvent, to event: NSEvent) -> Bool {
    let dx = event.locationInWindow.x - startEvent.locationInWindow.x
    let dy = event.locationInWindow.y - startEvent.locationInWindow.y
    return hypot(dx, dy) >= Constants.dragThreshold
  }

  private func beginPaletteDrag(with event: NSEvent) {
    let item = policyCanvasPalettePasteboardItem(payload: payload)
    let draggingItem = NSDraggingItem(pasteboardWriter: item)
    draggingItem.setDraggingFrame(draggingFrame(for: event), contents: draggingImage())
    beginDraggingSession(with: [draggingItem], event: event, source: self)
  }

  private func draggingFrame(for event: NSEvent) -> NSRect {
    let imageSize = draggingImageSize()
    let localPoint = convert(event.locationInWindow, from: nil)
    return NSRect(
      x: localPoint.x - Constants.previewIconWidth,
      y: localPoint.y - imageSize.height / 2,
      width: imageSize.width,
      height: imageSize.height
    )
  }

  private func draggingImageSize() -> NSSize {
    let titleWidth = (previewTitle as NSString).size(withAttributes: titleAttributes).width
    let width = min(
      Constants.previewMaxWidth,
      Constants.previewHorizontalPadding * 2 + Constants.previewIconWidth + Constants.previewSpacing
        + titleWidth
    )
    return NSSize(width: width, height: Constants.previewHeight)
  }

  private var titleAttributes: [NSAttributedString.Key: Any] {
    [
      .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: NSColor.labelColor,
    ]
  }

  private func draggingImage() -> NSImage {
    let size = draggingImageSize()
    let image = NSImage(size: size)
    image.lockFocus()
    drawDraggingImageBackground(in: NSRect(origin: .zero, size: size))
    drawDraggingImageSymbol(in: size)
    drawDraggingImageTitle(in: size)
    image.unlockFocus()
    return image
  }

  private func drawDraggingImageBackground(in rect: NSRect) {
    let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
    NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
    backgroundPath.fill()
    NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
    backgroundPath.lineWidth = 1
    backgroundPath.stroke()
  }

  private func drawDraggingImageSymbol(in size: NSSize) {
    guard let symbol = NSImage(systemSymbolName: previewSymbolName, accessibilityDescription: nil)
    else {
      return
    }
    let symbolRect = NSRect(
      x: Constants.previewHorizontalPadding,
      y: (size.height - Constants.previewIconWidth) / 2,
      width: Constants.previewIconWidth,
      height: Constants.previewIconWidth
    )
    symbol.draw(in: symbolRect)
  }

  private func drawDraggingImageTitle(in size: NSSize) {
    let titleWidth = max(
      1,
      size.width - Constants.previewHorizontalPadding * 2 - Constants.previewIconWidth
        - Constants.previewSpacing
    )
    let titleRect = NSRect(
      x: Constants.previewHorizontalPadding + Constants.previewIconWidth + Constants.previewSpacing,
      y: (size.height - 16) / 2,
      width: titleWidth,
      height: 18
    )
    (previewTitle as NSString).draw(in: titleRect, withAttributes: titleAttributes)
  }
}

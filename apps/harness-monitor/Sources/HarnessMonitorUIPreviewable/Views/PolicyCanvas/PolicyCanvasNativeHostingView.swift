import AppKit
import HarnessMonitorKit
import SwiftUI

@MainActor
func policyCanvasApplyOpaqueViewportBacking(to view: NSView) {
  view.wantsLayer = true
  view.layer?.masksToBounds = true
  view.layer?.isOpaque = true
  var backgroundColor = NSColor.textBackgroundColor.cgColor
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    backgroundColor = NSColor.textBackgroundColor.cgColor
  }
  view.layer?.backgroundColor = backgroundColor
}

@MainActor
final class PolicyCanvasNativeHostingView: NSHostingView<PolicyCanvasViewportHostedRoot> {
  weak var documentInteractionDelegate: PolicyCanvasNativeDocumentView?

  override var isOpaque: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  func configureCanvasRenderingSurface() {
    policyCanvasApplyOpaqueViewportBacking(to: self)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureCanvasRenderingSurface()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    configureCanvasRenderingSurface()
  }

  override func mouseDown(with event: NSEvent) {
    rootView.state.requestKeyboardFocus?()
    if HarnessMonitorUITestTrace.isEnabled {
      HarnessMonitorUITestTrace.record(
        component: "policy-canvas.native",
        event: "hosting.mouse.down",
        details: ["click_count": String(event.clickCount)]
      )
    }
    if documentInteractionDelegate?.routeMouseDown(event) == true {
      return
    }
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    if documentInteractionDelegate?.routeMouseDragged(event) == true {
      return
    }
    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if documentInteractionDelegate?.routeMouseUp(event) == true {
      return
    }
    super.mouseUp(with: event)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    documentInteractionDelegate?.routeDraggingEntered(sender) ?? super.draggingEntered(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    documentInteractionDelegate?.routeDraggingUpdated(sender) ?? super.draggingUpdated(sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    documentInteractionDelegate?.routeDraggingExited(sender)
    super.draggingExited(sender)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    documentInteractionDelegate?.routePrepareForDragOperation(sender)
      ?? super.prepareForDragOperation(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    documentInteractionDelegate?.routePerformDragOperation(sender)
      ?? super.performDragOperation(sender)
  }
}

@MainActor
func policyCanvasDraggingStrings(_ sender: NSDraggingInfo) -> [String] {
  if let strings = sender.draggingPasteboard.readObjects(
    forClasses: [NSString.self],
    options: nil
  ) as? [NSString],
    !strings.isEmpty
  {
    return strings.map(String.init)
  }
  guard let string = sender.draggingPasteboard.string(forType: .string) else {
    return []
  }
  return [string]
}

@MainActor
final class PolicyCanvasTestingDocumentView<Content: View>: NSView {
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }

  private let hostingView: NSHostingView<Content>

  init(rootView: Content) {
    hostingView = NSHostingView(rootView: rootView)
    super.init(frame: .zero)
    policyCanvasApplyOpaqueViewportBacking(to: self)
    policyCanvasApplyOpaqueViewportBacking(to: hostingView)
    addSubview(hostingView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    hostingView.frame = bounds
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    policyCanvasApplyOpaqueViewportBacking(to: self)
    policyCanvasApplyOpaqueViewportBacking(to: hostingView)
  }

  func updateSize(_ size: CGSize) {
    frame = CGRect(origin: .zero, size: size)
    hostingView.frame = bounds
    needsLayout = true
  }
}

import AppKit
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI
import UniformTypeIdentifiers

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
func policyCanvasFixedFittingSize(
  for size: CGSize,
  fallback: CGSize = .zero
) -> NSSize {
  if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
    return NSSize(width: size.width, height: size.height)
  }
  if fallback.width.isFinite, fallback.height.isFinite, fallback.width > 0, fallback.height > 0 {
    return NSSize(width: fallback.width, height: fallback.height)
  }
  return NSSize(width: 1, height: 1)
}

let policyCanvasAcceptedTextPasteboardTypes: [NSPasteboard.PasteboardType] = {
  var seen = Set<String>()
  return [
    NSPasteboard.PasteboardType.string,
    NSPasteboard.PasteboardType(UTType.plainText.identifier),
    NSPasteboard.PasteboardType(UTType.text.identifier),
  ].filter { seen.insert($0.rawValue).inserted }
}()

@MainActor
final class PolicyCanvasNativeHostingView: NSHostingView<PolicyCanvasViewportHostedRoot> {
  weak var documentInteractionDelegate: PolicyCanvasNativeDocumentView?

  override var isOpaque: Bool { true }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override var fittingSize: NSSize {
    policyCanvasFixedFittingSize(for: bounds.size)
  }

  required init(rootView: PolicyCanvasViewportHostedRoot) {
    super.init(rootView: rootView)
    sizingOptions = []
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Intentionally no `layout()` override / one-shot layout gate. NSHostingView
  // already marks itself `needsLayout` only when the hosted root's observed
  // state changes, and the child layers render live viewModel state - selection,
  // hover marks, marquee, the pending-edge rubber band - that is deliberately
  // kept out of the snapshot `renderSignature` (so a pure scroll/pan does not
  // republish the whole tree). A gate that skipped `super.layout()` for anything
  // not routed through `replaceRootView`/`updateSize` froze those interaction
  // repaints: clicking a node showed no selection border and the quality hover
  // overlay never updated. Let the framework's own invalidation drive layout.
  // The interaction-churn wins come from the renderSignature snapshot gate and
  // the zoom/viewport debounce, which both remain.

  func markHostedLayoutRequired() {
    if !needsLayout {
      needsLayout = true
    }
  }

  func replaceRootView(_ rootView: PolicyCanvasViewportHostedRoot) {
    markHostedLayoutRequired()
    self.rootView = rootView
  }

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
  policyCanvasStrings(from: sender.draggingPasteboard)
}

@MainActor
func policyCanvasStrings(from pasteboard: NSPasteboard) -> [String] {
  if let strings = pasteboard.readObjects(
    forClasses: [NSString.self],
    options: nil
  ) as? [NSString],
    !strings.isEmpty
  {
    return strings.map(String.init)
  }
  for pasteboardType in policyCanvasAcceptedTextPasteboardTypes {
    if let string = pasteboard.string(forType: pasteboardType) {
      return [string]
    }
  }
  return []
}

@MainActor
final class PolicyCanvasTestingDocumentView<Content: View>: NSView {
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override var fittingSize: NSSize {
    policyCanvasFixedFittingSize(for: frame.size, fallback: bounds.size)
  }

  private let hostingView: NSHostingView<Content>

  init(rootView: Content) {
    hostingView = NSHostingView(rootView: rootView)
    super.init(frame: .zero)
    hostingView.sizingOptions = []
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
    if hostingView.frame != bounds {
      hostingView.frame = bounds
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    policyCanvasApplyOpaqueViewportBacking(to: self)
    policyCanvasApplyOpaqueViewportBacking(to: hostingView)
  }

  func updateSize(_ size: CGSize) {
    guard frame.size != size || hostingView.frame.size != size else {
      return
    }
    frame = CGRect(origin: .zero, size: size)
    if hostingView.frame != bounds {
      hostingView.frame = bounds
    }
    if !needsLayout {
      needsLayout = true
    }
  }
}

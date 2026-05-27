import AppKit
import SwiftUI

struct PolicyCanvasViewportScrollRequest: Equatable {
  let id: UInt64
  let point: CGPoint
  let consumesViewportCenteringRequest: Bool
}

struct PolicyCanvasViewportNativeHost<Content: View>: NSViewRepresentable {
  var content: Content
  var contentSize: CGSize
  var zoom: CGFloat
  var isActive = true
  var isEmpty = false
  var request: PolicyCanvasViewportScrollRequest?
  var onFulfillRequest: @MainActor (PolicyCanvasViewportScrollRequest, Bool) -> Void
  var onZoomChange: @MainActor (CGFloat) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> PolicyCanvasNativeScrollView {
    let scrollView = PolicyCanvasNativeScrollView()
    scrollView.magnificationDidChange = { [weak coordinator = context.coordinator] zoom in
      coordinator?.handleViewportZoomChange(zoom)
    }
    return scrollView
  }

  func updateNSView(_ scrollView: PolicyCanvasNativeScrollView, context: Context) {
    context.coordinator.onFulfillRequest = onFulfillRequest
    context.coordinator.onZoomChange = onZoomChange
    scrollView.magnificationDidChange = { [weak coordinator = context.coordinator] zoom in
      coordinator?.handleViewportZoomChange(zoom)
    }
    scrollView.setInteractionEnabled(isActive && !isEmpty)
    scrollView.setDocumentContent(content, size: contentSize)
    context.coordinator.applyModelZoomIfNeeded(zoom, to: scrollView)
    context.coordinator.updateRequest(request)
    context.coordinator.applyPendingRequest(on: scrollView)
  }

  @MainActor
  final class Coordinator {
    var onFulfillRequest: ((PolicyCanvasViewportScrollRequest, Bool) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?
    private var request: PolicyCanvasViewportScrollRequest?
    private var appliedRequest: PolicyCanvasViewportScrollRequest?
    private var isApplyingModelZoom = false
    private var isRetryScheduled = false

    func updateRequest(_ request: PolicyCanvasViewportScrollRequest?) {
      guard self.request != request else {
        return
      }
      self.request = request
    }

    func handleViewportZoomChange(_ zoom: CGFloat) {
      guard !isApplyingModelZoom else {
        return
      }
      onZoomChange?(zoom)
    }

    func applyModelZoomIfNeeded(
      _ zoom: CGFloat,
      to scrollView: PolicyCanvasNativeScrollView
    ) {
      guard abs(scrollView.magnification - zoom) > 0.001 else {
        return
      }
      isApplyingModelZoom = true
      scrollView.setMagnification(zoom, centeredAt: scrollView.visibleDocumentCenter)
      isApplyingModelZoom = false
    }

    func applyPendingRequest(on scrollView: PolicyCanvasNativeScrollView) {
      guard let request, appliedRequest != request else {
        return
      }
      switch scrollView.applyScrollRequest(request.point) {
      case .applied(let didScroll):
        onFulfillRequest?(request, didScroll)
        appliedRequest = request
        isRetryScheduled = false
      case .needsRetry:
        scheduleRetry(on: scrollView, request: request)
      }
    }

    private func scheduleRetry(
      on scrollView: PolicyCanvasNativeScrollView,
      request: PolicyCanvasViewportScrollRequest
    ) {
      guard !isRetryScheduled else {
        return
      }
      isRetryScheduled = true
      DispatchQueue.main.async { [weak self, weak scrollView] in
        guard let self else {
          return
        }
        self.isRetryScheduled = false
        guard let scrollView, self.request == request else {
          return
        }
        self.applyPendingRequest(on: scrollView)
      }
    }
  }
}

@MainActor
final class PolicyCanvasNativeScrollView: NSScrollView {
  enum ScrollRequestResult: Equatable {
    case applied(Bool)
    case needsRetry
  }

  var magnificationDidChange: ((CGFloat) -> Void)?

  private let centeringClipView = PolicyCanvasCenteringClipView()
  private var interactionEnabled = true

  init() {
    super.init(frame: .zero)
    drawsBackground = false
    borderType = .noBorder
    scrollerStyle = .overlay
    hasHorizontalScroller = true
    hasVerticalScroller = true
    autohidesScrollers = false
    allowsMagnification = true
    minMagnification = PolicyCanvasLayout.minimumZoom
    maxMagnification = PolicyCanvasLayout.maximumZoom
    usesPredominantAxisScrolling = false
    contentView = centeringClipView
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var visibleDocumentCenter: CGPoint {
    let visibleRect = documentVisibleRect
    return CGPoint(x: visibleRect.midX, y: visibleRect.midY)
  }

  func setInteractionEnabled(_ isEnabled: Bool) {
    interactionEnabled = isEnabled
    allowsMagnification = isEnabled
    hasHorizontalScroller = isEnabled
    hasVerticalScroller = isEnabled
    horizontalScrollElasticity = isEnabled ? .automatic : .none
    verticalScrollElasticity = isEnabled ? .automatic : .none
  }

  func setDocumentContent<Content: View>(_ content: Content, size: CGSize) {
    let hostedDocumentView: PolicyCanvasNativeDocumentView<Content>
    if let existingDocumentView = documentView as? PolicyCanvasNativeDocumentView<Content> {
      hostedDocumentView = existingDocumentView
    } else {
      let newDocumentView = PolicyCanvasNativeDocumentView(rootView: content)
      documentView = newDocumentView
      hostedDocumentView = newDocumentView
    }
    hostedDocumentView.update(rootView: content, size: size)
    contentView.scroll(to: contentView.bounds.origin)
    reflectScrolledClipView(contentView)
  }

  func applyScrollRequest(_ point: CGPoint) -> ScrollRequestResult {
    guard contentView.bounds.width > 1, contentView.bounds.height > 1 else {
      return .needsRetry
    }
    let target = clampedDocumentPoint(point)
    let current = currentDocumentOffset
    let shouldScroll = abs(current.x - target.x) > 1 || abs(current.y - target.y) > 1
    if shouldScroll {
      contentView.scroll(to: target)
      reflectScrolledClipView(contentView)
    }
    return .applied(shouldScroll)
  }

  override func magnify(with event: NSEvent) {
    guard interactionEnabled else {
      return
    }
    super.magnify(with: event)
    magnificationDidChange?(magnification)
  }

  override func scrollWheel(with event: NSEvent) {
    usesPredominantAxisScrolling = false
    guard interactionEnabled else {
      return
    }
    if event.modifierFlags.contains(.command) {
      guard
        let deltaY = policyCanvasCommandScrollDeltaY(event: event),
        let targetZoom = policyCanvasCommandScrollTargetZoom(
          currentZoom: magnification,
          deltaY: deltaY
        ),
        let documentView
      else {
        return
      }
      let anchor = documentView.convert(event.locationInWindow, from: nil)
      setMagnification(targetZoom, centeredAt: anchor)
      magnificationDidChange?(magnification)
      return
    }
    super.scrollWheel(with: event)
  }

  private var currentDocumentOffset: CGPoint {
    let origin = documentVisibleRect.origin
    return CGPoint(x: max(0, origin.x), y: max(0, origin.y))
  }

  private func clampedDocumentPoint(_ point: CGPoint) -> CGPoint {
    let maxOffset = maxDocumentOffset
    return CGPoint(
      x: min(max(0, point.x), maxOffset.x),
      y: min(max(0, point.y), maxOffset.y)
    )
  }

  private var maxDocumentOffset: CGPoint {
    guard let documentView else {
      return .zero
    }
    return CGPoint(
      x: max(0, documentView.frame.width - contentView.bounds.width),
      y: max(0, documentView.frame.height - contentView.bounds.height)
    )
  }
}

final class PolicyCanvasCenteringClipView: NSClipView {
  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var constrained = super.constrainBoundsRect(proposedBounds)
    guard let documentView else {
      return constrained
    }
    if documentView.frame.width < constrained.width {
      constrained.origin.x = -((constrained.width - documentView.frame.width) / 2)
    }
    if documentView.frame.height < constrained.height {
      constrained.origin.y = -((constrained.height - documentView.frame.height) / 2)
    }
    return constrained
  }
}

final class PolicyCanvasNativeDocumentView<Content: View>: NSView {
  override var isFlipped: Bool { true }

  private let hostingView: NSHostingView<Content>

  init(rootView: Content) {
    hostingView = NSHostingView(rootView: rootView)
    super.init(frame: .zero)
    addSubview(hostingView)
  }

  override init(frame frameRect: NSRect) {
    fatalError("init(frame:) has not been implemented")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    hostingView.frame = bounds
  }

  func update(rootView: Content, size: CGSize) {
    hostingView.rootView = rootView
    frame = CGRect(origin: .zero, size: size)
    hostingView.frame = bounds
    needsLayout = true
  }
}

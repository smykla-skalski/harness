import AppKit
import SwiftUI

struct PolicyCanvasCommandScrollRequest: Equatable {
  var zoom: CGFloat?
  var scrollPoint: CGPoint
}

struct PolicyCanvasViewportScrollRequest: Equatable {
  let id: UInt64
  let point: CGPoint
  let consumesViewportCenteringRequest: Bool
}

@MainActor
final class PolicyCanvasCommandScrollCoordinator {
  private var generation: UInt64 = 0
  private var hasPendingRestoration = false

  func consumePendingRestoration() -> Bool {
    guard hasPendingRestoration else {
      return false
    }
    hasPendingRestoration = false
    return true
  }

  func schedule(
    _ request: PolicyCanvasCommandScrollRequest,
    apply: @escaping @MainActor (PolicyCanvasCommandScrollRequest) -> Void
  ) {
    generation &+= 1
    let scheduledGeneration = generation
    Task { @MainActor in
      await Task.yield()
      await Task.yield()
      guard self.generation == scheduledGeneration else {
        return
      }
      self.hasPendingRestoration = true
      apply(request)
    }
  }

  func armPendingRestoration() {
    hasPendingRestoration = true
  }
}

struct PolicyCanvasViewportScrollApplicator: NSViewRepresentable {
  var request: PolicyCanvasViewportScrollRequest?
  var onFulfillRequest: @MainActor (PolicyCanvasViewportScrollRequest, Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> PolicyCanvasViewportScrollApplicatorView {
    let view = PolicyCanvasViewportScrollApplicatorView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_ view: PolicyCanvasViewportScrollApplicatorView, context: Context) {
    context.coordinator.onFulfillRequest = onFulfillRequest
    view.updatePendingRequestID(request?.id)
    if context.coordinator.updateRequest(request) {
      view.applyScrollWhenReady()
    }
  }

  @MainActor
  final class Coordinator {
    enum ApplyRequestResult {
      case idle
      case applied
      case needsRetry
    }

    var request: PolicyCanvasViewportScrollRequest?
    var onFulfillRequest: ((PolicyCanvasViewportScrollRequest, Bool) -> Void)?
    private var appliedRequest: PolicyCanvasViewportScrollRequest?
    private weak var cachedScrollView: NSScrollView?

    var hasPendingRequest: Bool {
      guard let request else {
        return false
      }
      return appliedRequest != request
    }

    func updateRequest(_ request: PolicyCanvasViewportScrollRequest?) -> Bool {
      guard self.request != request else {
        return false
      }
      self.request = request
      return request != nil
    }

    func configureScrollViewIfAvailable(from view: NSView) {
      guard let scrollView = resolvedScrollView(from: view) else {
        return
      }
      Self.configureViewportScrolling(in: scrollView)
    }

    @MainActor
    func applyRequest(from view: NSView) -> ApplyRequestResult {
      guard let request, appliedRequest != request else {
        return .idle
      }
      guard let scrollView = resolvedScrollView(from: view) else {
        return .needsRetry
      }
      Self.configureViewportScrolling(in: scrollView)

      let maxOffset = Self.maxOffset(in: scrollView)
      guard !Self.needsAnotherLayoutPass(for: request.point, maxOffset: maxOffset) else {
        return .needsRetry
      }

      let targetPoint = Self.clampedPoint(request.point, maxOffset: maxOffset)
      let shouldScroll = Self.shouldScroll(to: targetPoint, in: scrollView)
      onFulfillRequest?(request, shouldScroll)
      if shouldScroll {
        Self.setPoint(targetPoint, in: scrollView)
      }
      appliedRequest = request
      return .applied
    }

    @MainActor
    private func resolvedScrollView(from view: NSView) -> NSScrollView? {
      if let cachedScrollView,
        Self.isRestorationCandidate(cachedScrollView, for: view)
      {
        return cachedScrollView
      }

      guard let scrollView = Self.findNearestScrollView(from: view) else {
        return nil
      }
      cachedScrollView = scrollView
      return scrollView
    }

    private static func findNearestScrollView(from view: NSView) -> NSScrollView? {
      if let enclosingScrollView = view.enclosingScrollView,
        isRestorationCandidate(enclosingScrollView, for: view)
      {
        return enclosingScrollView
      }

      guard let window = view.window,
        let contentView = window.contentView
      else {
        return nil
      }

      let viewFrame = view.convert(view.bounds, to: nil)
      let scrollViews = descendantScrollViews(in: contentView).filter { scrollView in
        isRestorationCandidate(scrollView, in: window)
      }
      let containingMidpoint = scrollViews.filter { scrollView in
        scrollView.convert(scrollView.bounds, to: nil).contains(
          NSPoint(x: viewFrame.midX, y: viewFrame.midY)
        )
      }

      if let scrollView = largestScrollView(containingMidpoint) {
        return scrollView
      }

      return scrollViews.max { left, right in
        intersectionArea(left, with: viewFrame) < intersectionArea(right, with: viewFrame)
      }
    }

    private static func isRestorationCandidate(_ scrollView: NSScrollView, for view: NSView)
      -> Bool
    {
      guard let window = view.window else {
        return false
      }
      return isRestorationCandidate(scrollView, in: window)
    }

    private static func isRestorationCandidate(_ scrollView: NSScrollView, in window: NSWindow)
      -> Bool
    {
      scrollView.window === window
        && !scrollView.isHidden
        && !scrollView.frame.isEmpty
        && scrollView.documentView != nil
    }

    private static func currentOffset(in scrollView: NSScrollView) -> CGPoint {
      let visibleOrigin = scrollView.documentVisibleRect.origin
      let maxOffset = maxOffset(in: scrollView)
      let y: CGFloat
      if scrollView.documentView?.isFlipped == false {
        y = maxOffset.y - visibleOrigin.y
      } else {
        y = visibleOrigin.y
      }
      return CGPoint(x: visibleOrigin.x, y: y)
    }

    private static func configureViewportScrolling(in scrollView: NSScrollView) {
      scrollView.usesPredominantAxisScrolling = false
    }

    private static func maxOffset(in scrollView: NSScrollView) -> CGPoint {
      guard let documentView = scrollView.documentView else {
        return .zero
      }
      return CGPoint(
        x: max(0, documentView.frame.width - scrollView.contentView.bounds.width),
        y: max(0, documentView.frame.height - scrollView.contentView.bounds.height)
      )
    }

    private static func clampedPoint(_ point: CGPoint, maxOffset: CGPoint) -> CGPoint {
      CGPoint(
        x: min(max(0, point.x), maxOffset.x),
        y: min(max(0, point.y), maxOffset.y)
      )
    }

    private static func needsAnotherLayoutPass(
      for requestedPoint: CGPoint,
      maxOffset: CGPoint
    ) -> Bool {
      (requestedPoint.x > 1 && maxOffset.x <= 0)
        || (requestedPoint.y > 1 && maxOffset.y <= 0)
    }

    private static func shouldScroll(to point: CGPoint, in scrollView: NSScrollView) -> Bool {
      let current = currentOffset(in: scrollView)
      return abs(current.x - point.x) > 1 || abs(current.y - point.y) > 1
    }

    private static func setPoint(_ point: CGPoint, in scrollView: NSScrollView) {
      let maxOffset = maxOffset(in: scrollView)
      let clamped = clampedPoint(point, maxOffset: maxOffset)
      let documentY: CGFloat
      if scrollView.documentView?.isFlipped == false {
        documentY = maxOffset.y - clamped.y
      } else {
        documentY = clamped.y
      }
      let contentView = scrollView.contentView
      contentView.scroll(to: NSPoint(x: clamped.x, y: documentY))
      scrollView.reflectScrolledClipView(contentView)
    }

    private static func largestScrollView(_ scrollViews: [NSScrollView]) -> NSScrollView? {
      scrollViews.max { left, right in
        area(left.convert(left.bounds, to: nil)) < area(right.convert(right.bounds, to: nil))
      }
    }

    private static func area(_ rect: NSRect) -> CGFloat {
      guard !rect.isEmpty else {
        return 0
      }
      return rect.width * rect.height
    }

    private static func intersectionArea(_ scrollView: NSScrollView, with frame: NSRect)
      -> CGFloat
    {
      let intersection = scrollView.convert(scrollView.bounds, to: nil).intersection(frame)
      return area(intersection)
    }

    private static func descendantScrollViews(in root: NSView) -> [NSScrollView] {
      var result: [NSScrollView] = []
      var stack = [root]
      while let view = stack.popLast() {
        if let scrollView = view as? NSScrollView {
          result.append(scrollView)
        }
        stack.append(contentsOf: view.subviews)
      }
      return result
    }
  }
}

@MainActor
final class PolicyCanvasViewportScrollApplicatorView: NSView {
  private static let maxRetryAttempts = 24

  weak var coordinator: PolicyCanvasViewportScrollApplicator.Coordinator?
  private var isApplyScheduled = false
  private var pendingRequestID: UInt64?
  private var retryAttemptCount = 0

  override var intrinsicContentSize: NSSize {
    .zero
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureScrollViewIfAvailable()
    applyScrollWhenReady()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    configureScrollViewIfAvailable()
    applyScrollWhenReady()
  }

  override func layout() {
    super.layout()
    configureScrollViewIfAvailable()
    applyScrollWhenReady()
  }

  func updatePendingRequestID(_ requestID: UInt64?) {
    guard pendingRequestID != requestID else { return }
    pendingRequestID = requestID
    retryAttemptCount = 0
  }

  func applyScrollWhenReady() {
    guard let coordinator, coordinator.hasPendingRequest, !isApplyScheduled else { return }
    isApplyScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.isApplyScheduled = false
      switch coordinator.applyRequest(from: self) {
      case .idle, .applied:
        self.retryAttemptCount = 0
      case .needsRetry:
        self.scheduleRetryIfNeeded()
      }
    }
  }

  private func scheduleRetryIfNeeded() {
    guard window != nil, pendingRequestID != nil else { return }
    guard retryAttemptCount < Self.maxRetryAttempts else { return }
    retryAttemptCount += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + (1.0 / 60.0)) { [weak self] in
      self?.applyScrollWhenReady()
    }
  }

  private func configureScrollViewIfAvailable() {
    coordinator?.configureScrollViewIfAvailable(from: self)
  }
}

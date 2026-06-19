import AppKit
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

public enum PolicyCanvasViewportResizeZoomBehavior: Equatable {
  case preserveZoom
  case scaleProportionally
}

@MainActor
final class PolicyCanvasNativeScrollView: NSScrollView {
  enum ScrollRequestResult: Equatable {
    case applied(Bool)
    case needsRetry
  }

  var magnificationDidChange: ((CGFloat) -> Void)?
  var viewportDidChange: ((PolicyCanvasViewportObservedState) -> Void)?
  var viewportResizeZoomBehavior: PolicyCanvasViewportResizeZoomBehavior = .preserveZoom

  private let centeringClipView = PolicyCanvasCenteringClipView()
  private var interactionEnabled = true
  var adaptiveWorkspaceLayout: PolicyCanvasAdaptiveWorkspaceLayout?
  var isAdjustingAdaptiveWorkspace = false
  var isPreservingViewportCenter = false
  private var isPreservingViewportFrameResize = false
  private var isApplyingViewportScrollRequest = false
  var hasLaidOutDocumentRootInViewport = false
  var lastReportedViewportState: PolicyCanvasViewportObservedState?
  var adaptiveExpansionArmed = false
  var isSamplingWheelScrollTarget = false
  var wheelScrollAnimation: PolicyCanvasWheelScrollAnimation?
  var wheelScrollSmoothingTimer: Timer?

  init() {
    super.init(frame: .zero)
    borderType = .noBorder
    scrollerStyle = .overlay
    hasHorizontalScroller = true
    hasVerticalScroller = true
    autohidesScrollers = false
    allowsMagnification = true
    minMagnification = PolicyCanvasLayout.minimumZoom
    maxMagnification = PolicyCanvasLayout.maximumZoom
    usesPredominantAxisScrolling = false
    horizontalScrollElasticity = .none
    verticalScrollElasticity = .none
    contentView = centeringClipView
    drawsBackground = false
    backgroundColor = .clear
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override var fittingSize: NSSize {
    policyCanvasFixedFittingSize(for: bounds.size, fallback: contentView.bounds.size)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var visibleDocumentCenter: CGPoint {
    let visibleRect = visibleWorkspaceRect
    return CGPoint(x: visibleRect.midX, y: visibleRect.midY)
  }

  override func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint) {
    guard
      let adaptiveWorkspaceLayout,
      contentView.bounds.width > 1,
      contentView.bounds.height > 1,
      documentView != nil
    else {
      super.setMagnification(magnification, centeredAt: point)
      return
    }
    let visibleRect = visibleWorkspaceRect
    let anchorUnit = CGPoint(
      x: (point.x - visibleRect.minX) / visibleRect.width,
      y: (point.y - visibleRect.minY) / visibleRect.height
    )
    let contentAnchor = adaptiveWorkspaceLayout.contentPoint(forWorkspacePoint: point)

    isPreservingViewportCenter = true
    super.setMagnification(magnification, centeredAt: point)
    scrollToPreserveContentAnchor(contentAnchor, viewportUnitAnchor: anchorUnit)
    super.reflectScrolledClipView(contentView)
    isPreservingViewportCenter = false
    reportViewportStateIfNeeded()
  }

  func setInteractionEnabled(_ isEnabled: Bool) {
    if !isEnabled {
      cancelWheelScrollSmoothing()
    }
    interactionEnabled = isEnabled
    allowsMagnification = isEnabled
    hasHorizontalScroller = isEnabled
    hasVerticalScroller = isEnabled
    horizontalScrollElasticity = .none
    verticalScrollElasticity = .none
  }

  func ensureDocumentRoot(
    state: PolicyCanvasViewportHostedState,
    size: CGSize
  ) {
    cancelWheelScrollSmoothing()
    let hadStableViewport =
      hasLaidOutDocumentRootInViewport
      && contentView.bounds.width > 1
      && contentView.bounds.height > 1
      && documentView != nil
    let canPreserveVisibleContent =
      hadStableViewport && adaptiveWorkspaceLayout?.contentSize == size
    let preservedContentCenter =
      canPreserveVisibleContent ? visibleContentCenterToPreserve() : nil
    let wasAdaptiveExpansionArmed = adaptiveExpansionArmed
    let workspaceLayout = policyCanvasAdaptiveWorkspaceLayout(
      current: adaptiveWorkspaceLayoutForCurrentViewport(
        contentSize: size,
        preservesVisibleContent: canPreserveVisibleContent
      ),
      contentSize: size,
      viewportSize: contentView.bounds.size
    )
    if adaptiveWorkspaceLayout != workspaceLayout {
      adaptiveWorkspaceLayout = workspaceLayout
    }
    state.update(workspaceLayout: workspaceLayout)
    let hostedDocumentView: PolicyCanvasNativeDocumentView
    if let existingDocumentView = documentView as? PolicyCanvasNativeDocumentView {
      hostedDocumentView = existingDocumentView
      hostedDocumentView.rebind(state: state)
    } else {
      let newDocumentView = PolicyCanvasNativeDocumentView(state: state)
      documentView = newDocumentView
      hostedDocumentView = newDocumentView
    }
    hostedDocumentView.updateSize(workspaceLayout.workspaceSize)
    if let preservedContentCenter {
      scrollToPreserveContentCenter(preservedContentCenter, in: workspaceLayout)
    }
    if preservedContentCenter != nil {
      adaptiveExpansionArmed = false
    }
    reflectDocumentRootUpdate(
      shouldExpand: wasAdaptiveExpansionArmed && preservedContentCenter == nil)
    if let preservedContentCenter {
      scrollToPreserveContentCenterIfPossible(preservedContentCenter)
    }
    markDocumentRootLaidOutIfPossible()
    reportViewportStateIfNeeded()
  }

  func setTestingDocumentContent<Content: View>(_ content: Content, size: CGSize) {
    cancelWheelScrollSmoothing()
    adaptiveWorkspaceLayout = nil
    lastReportedViewportState = nil
    adaptiveExpansionArmed = false
    hasLaidOutDocumentRootInViewport = false
    let testingDocumentView = PolicyCanvasTestingDocumentView(rootView: content)
    documentView = testingDocumentView
    testingDocumentView.updateSize(size)
    reflectScrolledClipView(contentView)
    markDocumentRootLaidOutIfPossible()
    reportViewportStateIfNeeded()
  }

  func applyScrollRequest(_ point: CGPoint) -> ScrollRequestResult {
    cancelWheelScrollSmoothing()
    guard contentView.bounds.width > 1, contentView.bounds.height > 1 else {
      return .needsRetry
    }
    let workspacePoint =
      adaptiveWorkspaceLayout?.workspacePoint(forContentPoint: point) ?? point
    let containedWorkspacePoint =
      expandAdaptiveWorkspaceIfNeeded(toContainViewportOrigin: workspacePoint)
    let target = clampedDocumentPoint(containedWorkspacePoint)
    let current = currentDocumentOffset
    let shouldScroll = abs(current.x - target.x) > 1 || abs(current.y - target.y) > 1
    if shouldScroll {
      isApplyingViewportScrollRequest = true
      defer { isApplyingViewportScrollRequest = false }
      contentView.scroll(to: target)
      reflectScrolledClipView(contentView)
    }
    reportViewportStateIfNeeded()
    return .applied(shouldScroll)
  }

  func applyScrollRequest(_ target: PolicyCanvasViewportScrollTarget) -> ScrollRequestResult {
    let point = target.contentOrigin(forVisibleContentSize: contentView.bounds.size)
    return applyScrollRequest(point)
  }

  override func magnify(with event: NSEvent) {
    guard interactionEnabled else {
      return
    }
    cancelWheelScrollSmoothing()
    super.magnify(with: event)
    magnificationDidChange?(magnification)
    reportViewportStateIfNeeded()
  }

  override func scrollWheel(with event: NSEvent) {
    usesPredominantAxisScrolling = false
    guard interactionEnabled else {
      cancelWheelScrollSmoothing()
      return
    }
    if event.modifierFlags.contains(.command) {
      cancelWheelScrollSmoothing()
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
    if smoothWheelScrollIfNeeded(for: event) {
      return
    }
    super.scrollWheel(with: event)
    armAdaptiveExpansionIfNeeded(for: contentView.bounds.origin)
    expandAdaptiveWorkspaceIfNeeded()
    reportViewportStateIfNeeded()
  }

  override func reflectScrolledClipView(_ clipView: NSClipView) {
    if isSamplingWheelScrollTarget {
      super.reflectScrolledClipView(clipView)
      return
    }
    if isPreservingViewportCenter
      || isPreservingViewportFrameResize
      || isApplyingViewportScrollRequest
    {
      super.reflectScrolledClipView(clipView)
      return
    }
    super.reflectScrolledClipView(clipView)
    armAdaptiveExpansionIfNeeded(for: clipView.bounds.origin)
    expandAdaptiveWorkspaceIfNeeded()
    reportViewportStateIfNeeded()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      cancelWheelScrollSmoothing()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func layout() {
    super.layout()
    markDocumentRootLaidOutIfPossible()
  }

  func beginViewportFrameResizePreservation() {
    isPreservingViewportFrameResize = true
  }

  func endViewportFrameResizePreservation() {
    isPreservingViewportFrameResize = false
  }

  func applyViewportFrameResizeZoomIfNeeded(
    from previousFrameSize: CGSize,
    to newFrameSize: CGSize,
    centeredAt preservedCenter: CGPoint
  ) -> Bool {
    guard viewportResizeZoomBehavior == .scaleProportionally else {
      return false
    }
    guard
      previousFrameSize.width > 1,
      previousFrameSize.height > 1,
      newFrameSize.width > 1,
      newFrameSize.height > 1
    else {
      return false
    }
    let resizeScale = min(
      newFrameSize.width / previousFrameSize.width,
      newFrameSize.height / previousFrameSize.height
    )
    guard resizeScale.isFinite, resizeScale > 0 else {
      return false
    }
    let targetZoom = policyCanvasClampedViewportResizeZoom(
      magnification * resizeScale,
      fallback: magnification
    )
    guard abs(targetZoom - magnification) > 0.001 else {
      return false
    }
    setMagnification(targetZoom, centeredAt: preservedCenter)
    contentView.scroll(
      to: CGPoint(
        x: preservedCenter.x - (contentView.bounds.width / 2),
        y: preservedCenter.y - (contentView.bounds.height / 2)
      )
    )
    super.reflectScrolledClipView(contentView)
    magnificationDidChange?(magnification)
    reportViewportStateIfNeeded()
    return true
  }

  private var currentDocumentOffset: CGPoint {
    let origin = visibleWorkspaceRect.origin
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

  private func armAdaptiveExpansionIfNeeded(for visibleOrigin: CGPoint) {
    guard adaptiveExpansionArmed == false else {
      return
    }
    if visibleOrigin.x > 1 || visibleOrigin.y > 1 {
      adaptiveExpansionArmed = true
    }
  }

  private func adaptiveWorkspaceLayoutForCurrentViewport(
    contentSize: CGSize,
    preservesVisibleContent: Bool
  ) -> PolicyCanvasAdaptiveWorkspaceLayout? {
    guard let adaptiveWorkspaceLayout else {
      return nil
    }
    guard !preservesVisibleContent else {
      return adaptiveWorkspaceLayout
    }
    guard adaptiveExpansionArmed == false else {
      return adaptiveWorkspaceLayout
    }
    let requiredInitialLayout = policyCanvasInitialAdaptiveWorkspaceLayout(
      contentSize: contentSize,
      viewportSize: contentView.bounds.size
    )
    if adaptiveWorkspaceLayout.contentOrigin.x + 0.5 < requiredInitialLayout.contentOrigin.x
      || adaptiveWorkspaceLayout.contentOrigin.y + 0.5 < requiredInitialLayout.contentOrigin.y
    {
      return nil
    }
    return adaptiveWorkspaceLayout
  }

  var visibleWorkspaceRect: CGRect {
    contentView.bounds
  }
}

private func policyCanvasClampedViewportResizeZoom(
  _ candidate: CGFloat,
  fallback: CGFloat
) -> CGFloat {
  guard candidate.isFinite else {
    return fallback
  }
  return min(
    PolicyCanvasLayout.maximumZoom,
    max(PolicyCanvasLayout.minimumZoom, candidate)
  )
}

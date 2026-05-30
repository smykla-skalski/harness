import AppKit
import HarnessMonitorKit
import SwiftUI

@MainActor
final class PolicyCanvasNativeScrollView: NSScrollView {
  enum ScrollRequestResult: Equatable {
    case applied(Bool)
    case needsRetry
  }

  var magnificationDidChange: ((CGFloat) -> Void)?
  var viewportDidChange: ((PolicyCanvasViewportObservedState) -> Void)?

  private let centeringClipView = PolicyCanvasCenteringClipView()
  private var interactionEnabled = true
  private var adaptiveWorkspaceLayout: PolicyCanvasAdaptiveWorkspaceLayout?
  private var isAdjustingAdaptiveWorkspace = false
  private var lastReportedViewportState: PolicyCanvasViewportObservedState?
  private var adaptiveExpansionArmed = false

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
    contentView = centeringClipView
    drawsBackground = false
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var visibleDocumentCenter: CGPoint {
    let visibleRect = visibleWorkspaceRect
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

  func ensureDocumentRoot(
    state: PolicyCanvasViewportHostedState,
    size: CGSize
  ) {
    let workspaceLayout = policyCanvasAdaptiveWorkspaceLayout(
      current: adaptiveWorkspaceLayoutForCurrentViewport(contentSize: size),
      contentSize: size,
      viewportSize: contentView.bounds.size
    )
    adaptiveWorkspaceLayout = workspaceLayout
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
    reflectScrolledClipView(contentView)
    expandAdaptiveWorkspaceIfNeeded()
    reportViewportStateIfNeeded()
  }

  func setTestingDocumentContent<Content: View>(_ content: Content, size: CGSize) {
    adaptiveWorkspaceLayout = nil
    lastReportedViewportState = nil
    adaptiveExpansionArmed = false
    let testingDocumentView = PolicyCanvasTestingDocumentView(rootView: content)
    documentView = testingDocumentView
    testingDocumentView.updateSize(size)
    reflectScrolledClipView(contentView)
    reportViewportStateIfNeeded()
  }

  func applyScrollRequest(_ point: CGPoint) -> ScrollRequestResult {
    guard contentView.bounds.width > 1, contentView.bounds.height > 1 else {
      return .needsRetry
    }
    let target = clampedDocumentPoint(
      adaptiveWorkspaceLayout?.workspacePoint(forContentPoint: point) ?? point
    )
    let current = currentDocumentOffset
    let shouldScroll = abs(current.x - target.x) > 1 || abs(current.y - target.y) > 1
    if shouldScroll {
      adaptiveExpansionArmed = true
      contentView.scroll(to: target)
      reflectScrolledClipView(contentView)
      expandAdaptiveWorkspaceIfNeeded()
    }
    reportViewportStateIfNeeded()
    return .applied(shouldScroll)
  }

  override func magnify(with event: NSEvent) {
    guard interactionEnabled else {
      return
    }
    super.magnify(with: event)
    magnificationDidChange?(magnification)
    reportViewportStateIfNeeded()
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
    armAdaptiveExpansionIfNeeded(for: contentView.bounds.origin)
    expandAdaptiveWorkspaceIfNeeded()
    reportViewportStateIfNeeded()
  }

  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    armAdaptiveExpansionIfNeeded(for: clipView.bounds.origin)
    expandAdaptiveWorkspaceIfNeeded()
    reportViewportStateIfNeeded()
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

  private func expandAdaptiveWorkspaceIfNeeded() {
    guard
      !isAdjustingAdaptiveWorkspace,
      adaptiveExpansionArmed,
      let adaptiveWorkspaceLayout,
      let hostedDocumentView = documentView as? PolicyCanvasNativeDocumentView,
      contentView.bounds.width > 1,
      contentView.bounds.height > 1
    else {
      return
    }

    let expansion = policyCanvasExpandedAdaptiveWorkspaceLayout(
      layout: adaptiveWorkspaceLayout,
      visibleWorkspaceRect: visibleWorkspaceRect,
      viewportSize: contentView.bounds.size
    )
    guard expansion.layout != adaptiveWorkspaceLayout else {
      return
    }

    isAdjustingAdaptiveWorkspace = true
    self.adaptiveWorkspaceLayout = expansion.layout
    hostedDocumentView.hostedState.update(workspaceLayout: expansion.layout)
    hostedDocumentView.updateSize(expansion.layout.workspaceSize)

    if expansion.scrollAdjustment != .zero {
      let visibleOrigin = visibleWorkspaceRect.origin
      contentView.scroll(
        to: CGPoint(
          x: visibleOrigin.x + expansion.scrollAdjustment.x,
          y: visibleOrigin.y + expansion.scrollAdjustment.y
        )
      )
    }

    super.reflectScrolledClipView(contentView)
    isAdjustingAdaptiveWorkspace = false
    reportViewportStateIfNeeded()
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
    contentSize: CGSize
  ) -> PolicyCanvasAdaptiveWorkspaceLayout? {
    guard let adaptiveWorkspaceLayout else {
      return nil
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

  private var visibleWorkspaceRect: CGRect {
    contentView.bounds
  }

  private func reportViewportStateIfNeeded() {
    let observedState = PolicyCanvasViewportObservedState(
      visibleContentRect: adaptiveWorkspaceLayout?.contentRect(
        forWorkspaceRect: visibleWorkspaceRect)
        ?? visibleWorkspaceRect,
      zoom: magnification
    )
    guard !approximatelyMatchesLastReportedViewportState(observedState) else {
      return
    }
    lastReportedViewportState = observedState
    viewportDidChange?(observedState)
  }

  private func approximatelyMatchesLastReportedViewportState(
    _ observedState: PolicyCanvasViewportObservedState
  ) -> Bool {
    guard let lastReportedViewportState else {
      return false
    }
    return abs(lastReportedViewportState.zoom - observedState.zoom) < 0.001
      && abs(
        lastReportedViewportState.visibleContentRect.minX - observedState.visibleContentRect.minX)
        < 0.5
      && abs(
        lastReportedViewportState.visibleContentRect.minY - observedState.visibleContentRect.minY)
        < 0.5
      && abs(
        lastReportedViewportState.visibleContentRect.width - observedState.visibleContentRect.width)
        < 0.5
      && abs(
        lastReportedViewportState.visibleContentRect.height
          - observedState.visibleContentRect.height)
        < 0.5
  }
}

final class PolicyCanvasCenteringClipView: NSClipView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    drawsBackground = false
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func setFrameSize(_ newSize: NSSize) {
    let preservedCenter: CGPoint?
    if bounds.width > 1, bounds.height > 1, documentView != nil {
      preservedCenter = CGPoint(x: bounds.midX, y: bounds.midY)
    } else {
      preservedCenter = nil
    }

    super.setFrameSize(newSize)

    guard let preservedCenter else {
      return
    }

    let targetOrigin = CGPoint(
      x: preservedCenter.x - (bounds.width / 2),
      y: preservedCenter.y - (bounds.height / 2)
    )
    guard
      abs(bounds.origin.x - targetOrigin.x) > 0.5
        || abs(bounds.origin.y - targetOrigin.y) > 0.5
    else {
      return
    }
    scroll(to: targetOrigin)
  }

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

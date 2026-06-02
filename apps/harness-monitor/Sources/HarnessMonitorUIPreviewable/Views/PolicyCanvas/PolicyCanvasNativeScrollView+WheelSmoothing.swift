import AppKit
import Foundation
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasNativeScrollView {
  func smoothWheelScrollIfNeeded(for event: NSEvent) -> Bool {
    guard PolicyCanvasWheelScrollSmoothing.shouldSmooth(event: event) else {
      return false
    }
    let startOrigin = contentView.bounds.origin
    let previousTargetOrigin = wheelScrollAnimation?.targetOrigin
    cancelWheelScrollSmoothing()

    isSamplingWheelScrollTarget = true
    super.scrollWheel(with: event)
    isSamplingWheelScrollTarget = false

    let sampledTargetOrigin = contentView.bounds.origin
    let targetOrigin = constrainedWheelScrollTarget(
      displayAlignedWheelScrollOrigin(
        PolicyCanvasWheelScrollSmoothing.accumulatedTargetOrigin(
          startOrigin: startOrigin,
          sampledTargetOrigin: sampledTargetOrigin,
          previousTargetOrigin: previousTargetOrigin
        )
      )
    )
    guard PolicyCanvasWheelScrollSmoothing.shouldAnimate(from: startOrigin, to: targetOrigin) else {
      reflectScrolledClipView(contentView)
      invalidateVisibleDocumentScrollRegion()
      return true
    }

    contentView.scroll(to: startOrigin)
    super.reflectScrolledClipView(contentView)
    invalidateVisibleDocumentScrollRegion()
    startWheelScrollSmoothing(from: startOrigin, to: targetOrigin)
    return true
  }

  func startWheelScrollSmoothing(
    from startOrigin: CGPoint,
    to targetOrigin: CGPoint
  ) {
    wheelScrollAnimation = PolicyCanvasWheelScrollAnimation(
      startOrigin: startOrigin,
      targetOrigin: targetOrigin,
      startTime: Date.timeIntervalSinceReferenceDate
    )
    let timer = Timer(
      timeInterval: PolicyCanvasWheelScrollSmoothing.frameInterval,
      repeats: true
    ) { [weak self] timer in
      let shouldInvalidate = MainActor.assumeIsolated {
        guard let self else {
          return true
        }
        return self.advanceWheelScrollSmoothing()
      }
      if shouldInvalidate {
        timer.invalidate()
      }
    }
    wheelScrollSmoothingTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func advanceWheelScrollSmoothing() -> Bool {
    guard let animation = wheelScrollAnimation else {
      wheelScrollSmoothingTimer = nil
      return true
    }

    let now = Date.timeIntervalSinceReferenceDate
    contentView.scroll(
      to: constrainedWheelScrollTarget(displayAlignedWheelScrollOrigin(animation.origin(at: now)))
    )
    reflectScrolledClipView(contentView)
    invalidateVisibleDocumentScrollRegion()

    if animation.isComplete(at: now) {
      cancelWheelScrollSmoothing()
      return true
    }
    return false
  }

  func cancelWheelScrollSmoothing() {
    wheelScrollSmoothingTimer?.invalidate()
    wheelScrollSmoothingTimer = nil
    wheelScrollAnimation = nil
  }

  private func displayAlignedWheelScrollOrigin(_ origin: CGPoint) -> CGPoint {
    PolicyCanvasWheelScrollSmoothing.devicePixelAlignedOrigin(
      origin,
      backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
      magnification: magnification
    )
  }

  private func constrainedWheelScrollTarget(_ origin: CGPoint) -> CGPoint {
    contentView.constrainBoundsRect(
      NSRect(origin: origin, size: contentView.bounds.size)
    )
    .origin
  }

  private func invalidateVisibleDocumentScrollRegion() {
    guard let documentView else {
      return
    }
    invalidateVisibleDocumentScrollRegion(
      in: documentView,
      visibleRect: contentView.bounds,
      documentView: documentView
    )
  }

  private func invalidateVisibleDocumentScrollRegion(
    in view: NSView,
    visibleRect: NSRect,
    documentView: NSView
  ) {
    let visibleRectInView = view.convert(visibleRect, from: documentView)
    let boundedRect = visibleRectInView.intersection(view.bounds)
    guard !boundedRect.isNull, boundedRect.width > 0, boundedRect.height > 0 else {
      return
    }
    view.setNeedsDisplay(boundedRect)
    for subview in view.subviews {
      invalidateVisibleDocumentScrollRegion(
        in: subview,
        visibleRect: visibleRect,
        documentView: documentView
      )
    }
  }
}

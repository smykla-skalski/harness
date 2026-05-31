import AppKit
import Foundation

extension PolicyCanvasNativeScrollView {
  func smoothWheelScrollIfNeeded(for event: NSEvent) -> Bool {
    guard PolicyCanvasWheelScrollSmoothing.shouldSmooth(event: event) else {
      return false
    }
    let startOrigin = contentView.bounds.origin
    cancelWheelScrollSmoothing()

    isSamplingWheelScrollTarget = true
    defer { isSamplingWheelScrollTarget = false }
    super.scrollWheel(with: event)

    let targetOrigin = contentView.bounds.origin
    guard PolicyCanvasWheelScrollSmoothing.shouldAnimate(from: startOrigin, to: targetOrigin) else {
      reflectScrolledClipView(contentView)
      return true
    }

    contentView.scroll(to: startOrigin)
    super.reflectScrolledClipView(contentView)
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
    contentView.scroll(to: animation.origin(at: now))
    reflectScrolledClipView(contentView)

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
}

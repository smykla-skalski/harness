import AppKit
import Foundation

enum PolicyCanvasWheelScrollSmoothing {
  static let frameInterval: TimeInterval = 1.0 / 120.0
  static let duration: TimeInterval = 0.14

  static func shouldSmooth(event: NSEvent) -> Bool {
    event.hasPreciseScrollingDeltas == false
      && event.phase.isEmpty
      && event.momentumPhase.isEmpty
      && !event.modifierFlags.contains(.command)
  }

  static func shouldAnimate(from startOrigin: CGPoint, to targetOrigin: CGPoint) -> Bool {
    abs(startOrigin.x - targetOrigin.x) > 0.5
      || abs(startOrigin.y - targetOrigin.y) > 0.5
  }

  static func easedProgress(
    elapsed: TimeInterval,
    duration: TimeInterval = Self.duration
  ) -> CGFloat {
    guard duration > 0 else {
      return 1
    }
    let rawProgress = min(1, max(0, elapsed / duration))
    let remaining = 1 - rawProgress
    return 1 - (remaining * remaining * remaining)
  }
}

struct PolicyCanvasWheelScrollAnimation: Equatable {
  let startOrigin: CGPoint
  let targetOrigin: CGPoint
  let startTime: TimeInterval
  let duration: TimeInterval

  init(
    startOrigin: CGPoint,
    targetOrigin: CGPoint,
    startTime: TimeInterval,
    duration: TimeInterval = PolicyCanvasWheelScrollSmoothing.duration
  ) {
    self.startOrigin = startOrigin
    self.targetOrigin = targetOrigin
    self.startTime = startTime
    self.duration = duration
  }

  func origin(at time: TimeInterval) -> CGPoint {
    let progress = PolicyCanvasWheelScrollSmoothing.easedProgress(
      elapsed: time - startTime,
      duration: duration
    )
    return CGPoint(
      x: startOrigin.x + ((targetOrigin.x - startOrigin.x) * progress),
      y: startOrigin.y + ((targetOrigin.y - startOrigin.y) * progress)
    )
  }

  func isComplete(at time: TimeInterval) -> Bool {
    time - startTime >= duration
  }
}

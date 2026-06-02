import AppKit
import Foundation
import HarnessMonitorPolicyCanvasAlgorithms

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

  static func accumulatedTargetOrigin(
    startOrigin: CGPoint,
    sampledTargetOrigin: CGPoint,
    previousTargetOrigin: CGPoint?
  ) -> CGPoint {
    let baseTargetOrigin = previousTargetOrigin ?? startOrigin
    return CGPoint(
      x: baseTargetOrigin.x + sampledTargetOrigin.x - startOrigin.x,
      y: baseTargetOrigin.y + sampledTargetOrigin.y - startOrigin.y
    )
  }

  static func devicePixelAlignedOrigin(
    _ origin: CGPoint,
    backingScale: CGFloat,
    magnification: CGFloat
  ) -> CGPoint {
    guard backingScale.isFinite, backingScale > 0, magnification.isFinite, magnification > 0
    else {
      return origin
    }
    let documentUnitsPerDevicePixel = 1 / (backingScale * magnification)
    guard documentUnitsPerDevicePixel.isFinite, documentUnitsPerDevicePixel > 0 else {
      return origin
    }
    return CGPoint(
      x: (origin.x / documentUnitsPerDevicePixel).rounded() * documentUnitsPerDevicePixel,
      y: (origin.y / documentUnitsPerDevicePixel).rounded() * documentUnitsPerDevicePixel
    )
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

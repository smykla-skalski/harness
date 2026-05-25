import SwiftUI

struct PolicyCanvasCommandScrollRequest: Equatable {
  var zoom: CGFloat?
  var scrollPoint: CGPoint
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

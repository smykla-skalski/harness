import Foundation

@MainActor
final class WindowRegistrySyncController {
  private enum PendingAction {
    case register(RegistryWindow)
    case unregister(Int)
  }

  private let registry: AccessibilityRegistry
  private var trackedWindowID: Int?
  private var trackingGeneration: UInt64 = 0
  private var pendingAction: PendingAction?
  private var flushTask: Task<Void, Never>?

  init(registry: AccessibilityRegistry) {
    self.registry = registry
  }

  func beginTracking(windowID: Int) -> UInt64 {
    trackingGeneration &+= 1
    trackedWindowID = windowID
    return trackingGeneration
  }

  func sync(_ entry: RegistryWindow, generation: UInt64) {
    guard generation == trackingGeneration, trackedWindowID == entry.id else { return }
    enqueue(.register(entry))
  }

  func stopTracking() {
    guard let windowID = trackedWindowID else { return }
    trackingGeneration &+= 1
    trackedWindowID = nil
    enqueue(.unregister(windowID))
  }

  func waitForIdle() async {
    while let task = flushTask {
      await task.value
    }
  }

  private func enqueue(_ action: PendingAction) {
    pendingAction = action
    guard flushTask == nil else { return }
    let registry = registry
    flushTask = Task { [weak self] in
      guard let self else { return }
      while let action = await MainActor.run(body: { self.takePendingActionOrFinish() }) {
        await Self.apply(action, to: registry)
      }
    }
  }

  private func takePendingActionOrFinish() -> PendingAction? {
    guard let action = pendingAction else {
      flushTask = nil
      return nil
    }
    pendingAction = nil
    return action
  }

  private static func apply(_ action: PendingAction, to registry: AccessibilityRegistry) async {
    switch action {
    case .register(let window):
      await registry.registerWindow(window)
    case .unregister(let windowID):
      await registry.unregisterWindow(id: windowID)
    }
  }
}

import Foundation

@MainActor
final class WindowRegistrySyncController {
  private enum PendingAction {
    case register(RegistryWindow, generation: UInt64, ownerID: UUID)
    case unregister(Int, ownerID: UUID)
  }

  private let registry: AccessibilityRegistry
  private var trackedWindowID: Int?
  private var trackingGeneration: UInt64 = 0
  private var trackingOwnerID = UUID()
  private var pendingUnregisters: [PendingAction] = []
  private var pendingRegistration: PendingAction?
  private var flushTask: Task<Void, Never>?

  init(registry: AccessibilityRegistry) {
    self.registry = registry
  }

  func beginTracking(windowID: Int) -> UInt64 {
    trackingGeneration &+= 1
    trackedWindowID = windowID
    trackingOwnerID = UUID()
    return trackingGeneration
  }

  func sync(_ entry: RegistryWindow, generation: UInt64) {
    guard generation == trackingGeneration, trackedWindowID == entry.id else { return }
    enqueue(.register(entry, generation: generation, ownerID: trackingOwnerID))
  }

  func stopTracking() {
    guard let windowID = trackedWindowID else { return }
    let ownerID = trackingOwnerID
    trackingGeneration &+= 1
    trackedWindowID = nil
    trackingOwnerID = UUID()
    enqueue(.unregister(windowID, ownerID: ownerID))
  }

  func waitForIdle() async {
    while let task = flushTask {
      await task.value
    }
  }

  private func enqueue(_ action: PendingAction) {
    switch action {
    case .register:
      pendingRegistration = action
    case .unregister:
      pendingUnregisters.append(action)
    }
    guard flushTask == nil else { return }
    let registry = registry
    flushTask = Task { [weak self] in
      guard let self else { return }
      while let action = await MainActor.run(body: { self.takePendingActionOrFinish() }) {
        await self.apply(action, to: registry)
      }
    }
  }

  private func takePendingActionOrFinish() -> PendingAction? {
    if pendingUnregisters.isEmpty == false {
      return pendingUnregisters.removeFirst()
    }
    if let pendingRegistration {
      self.pendingRegistration = nil
      return pendingRegistration
    }
    guard pendingUnregisters.isEmpty, pendingRegistration == nil else {
      return nil
    }
    flushTask = nil
    return nil
  }
 
  private func apply(_ action: PendingAction, to registry: AccessibilityRegistry) async {
    switch action {
    case .register(let window, let generation, let ownerID):
      guard
        generation == trackingGeneration,
        trackedWindowID == window.id,
        trackingOwnerID == ownerID
      else {
        return
      }
      await registry.registerTrackedWindow(window, ownerID: ownerID)
    case .unregister(let windowID, let ownerID):
      await registry.unregisterTrackedWindow(id: windowID, ownerID: ownerID)
    }
  }
}

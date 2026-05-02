import Foundation
import HarnessMonitorRegistry

extension HarnessMonitorMCPAccessibilityService {
  public func claimTrackedSemanticActions(identifier: String, ownerID: UUID) {
    trackedSemanticActionOwners[identifier] = ownerID
    if trackedSemanticActions[identifier]?.ownerID != ownerID {
      trackedSemanticActions[identifier] = nil
    }
  }

  public func registerPersistentSemanticElement(
    _ element: RegistryElement,
    semanticActions actions: RegistryTrackedSemanticActions = .none
  ) async {
    var element = element
    let ownerID = persistentSemanticElementOwners[element.identifier] ?? UUID()
    persistentSemanticElementOwners[element.identifier] = ownerID
    element.actions = actions.supportedActions
    await registry.claimTrackedElement(identifier: element.identifier, ownerID: ownerID)
    await registry.registerTrackedElement(element, ownerID: ownerID)
    claimTrackedSemanticActions(identifier: element.identifier, ownerID: ownerID)
    registerTrackedSemanticActions(
      identifier: element.identifier,
      semanticActions: actions,
      ownerID: ownerID
    )
  }

  public func unregisterPersistentSemanticElement(identifier: String) async {
    guard let ownerID = persistentSemanticElementOwners.removeValue(forKey: identifier) else {
      return
    }
    await registry.unregisterTrackedElement(identifier: identifier, ownerID: ownerID)
    unregisterTrackedSemanticActions(identifier: identifier, ownerID: ownerID)
  }

  public func registerTrackedSemanticActions(
    identifier: String,
    semanticActions actions: RegistryTrackedSemanticActions,
    ownerID: UUID
  ) {
    guard trackedSemanticActionOwners[identifier] == ownerID else {
      return
    }
    guard actions.supportedActions.isEmpty == false else {
      trackedSemanticActions[identifier] = nil
      return
    }
    trackedSemanticActions[identifier] = TrackedSemanticActionRegistration(
      ownerID: ownerID,
      semanticActions: actions
    )
  }

  public func clearTrackedSemanticActions(identifier: String, ownerID: UUID) {
    guard trackedSemanticActionOwners[identifier] == ownerID else {
      return
    }
    if trackedSemanticActions[identifier]?.ownerID == ownerID {
      trackedSemanticActions[identifier] = nil
    }
  }

  public func unregisterTrackedSemanticActions(identifier: String, ownerID: UUID) {
    guard trackedSemanticActionOwners[identifier] == ownerID else {
      return
    }
    trackedSemanticActionOwners[identifier] = nil
    if trackedSemanticActions[identifier]?.ownerID == ownerID {
      trackedSemanticActions[identifier] = nil
    }
  }

  public func performSemanticAction(
    identifier: String,
    action: RegistrySemanticAction
  ) async -> RegistryRequestDispatcher.SemanticActionDisposition {
    guard let element = await registry.element(identifier: identifier) else {
      return .notFound
    }
    guard element.enabled else {
      return .actionUnavailable
    }
    guard
      let registration = trackedSemanticActions[identifier]
    else {
      return .actionUnavailable
    }

    let handler =
      switch action {
      case .press:
        registration.semanticActions.press
      }
    guard let handler else {
      return .actionUnavailable
    }

    handler()
    return .performed
  }
}

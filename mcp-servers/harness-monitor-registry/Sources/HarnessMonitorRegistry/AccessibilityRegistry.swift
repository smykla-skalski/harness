import Foundation

/// Thread-safe store for accessibility elements and windows exposed to the MCP server.
///
/// Views register themselves via `.trackAccessibility(...)` and the actor publishes the
/// results over the IPC socket.
public actor AccessibilityRegistry {
  private struct StoredWindow {
    let window: RegistryWindow
    let ownership: WindowOwnership
  }

  private enum WindowOwnership: Equatable {
    case manual
    case tracked(UUID)
  }

  private struct StoredElement {
    let element: RegistryElement
    let ownership: ElementOwnership
  }

  private enum ElementOwnership: Equatable {
    case manual
    case trackedElement(ownerID: UUID)
    case trackedWindowSnapshot(windowID: Int, ownerID: UUID)
  }

  private struct TrackedWindowElements {
    let ownerID: UUID
    var identifiers: Set<String>
  }

  private struct RemoteEndpoint: Equatable {
    let socketPath: String
  }

  private struct RemoteFlushPayload {
    let endpoint: RemoteEndpoint
    let snapshot: RegistryClientSnapshot
  }

  private var elements: [String: StoredElement] = [:]
  private var windows: [Int: StoredWindow] = [:]
  private var trackedWindowElements: [Int: TrackedWindowElements] = [:]
  // TrackAccessibility publishes asynchronously, so identifier ownership must be
  // claimed separately from element writes to ignore stale register/unregister tasks.
  private var trackedElementOwners: [String: UUID] = [:]
  private var clientSnapshots: [UUID: RegistryClientSnapshot] = [:]
  // Remote publication is latest-wins: local UI churn only needs the newest full
  // snapshot of this process, not every intermediate mutation on the wire.
  private var remoteEndpoint: RemoteEndpoint?
  private var remoteSnapshotDirty = false
  private var remoteFlushTask: Task<Void, Never>?

  private let clientID: UUID
  private let clientAppVersion: String
  private let clientBundleIdentifier: String
  private let remoteWriteRetryDelay: Duration
  private let remoteSocketClient: RegistrySocketClient

  public init(
    clientID: UUID = UUID(),
    clientAppVersion: String = (
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) ?? "0.0.0",
    clientBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.harnessmonitor.app",
    remoteWriteRetryDelay: Duration = .milliseconds(100),
    remoteSocketClient: RegistrySocketClient = RegistrySocketClient()
  ) {
    self.clientID = clientID
    self.clientAppVersion = clientAppVersion
    self.clientBundleIdentifier = clientBundleIdentifier
    self.remoteWriteRetryDelay = remoteWriteRetryDelay
    self.remoteSocketClient = remoteSocketClient
  }

  public func registerElement(_ element: RegistryElement) {
    applyRegisterElement(element)
    scheduleRemoteSnapshotFlush()
  }

  public func unregisterElement(identifier: String) {
    applyUnregisterElement(identifier: identifier)
    scheduleRemoteSnapshotFlush()
  }

  public func claimTrackedElement(identifier: String, ownerID: UUID) {
    applyClaimTrackedElement(identifier: identifier, ownerID: ownerID)
    scheduleRemoteSnapshotFlush()
  }

  public func registerTrackedElement(_ element: RegistryElement, ownerID: UUID) {
    applyRegisterTrackedElement(element, ownerID: ownerID)
    scheduleRemoteSnapshotFlush()
  }

  public func clearTrackedElement(identifier: String, ownerID: UUID) {
    applyClearTrackedElement(identifier: identifier, ownerID: ownerID)
    scheduleRemoteSnapshotFlush()
  }

  public func unregisterTrackedElement(identifier: String, ownerID: UUID) {
    applyUnregisterTrackedElement(identifier: identifier, ownerID: ownerID)
    scheduleRemoteSnapshotFlush()
  }

  public func registerWindow(_ window: RegistryWindow) {
    windows[window.id] = StoredWindow(window: window, ownership: .manual)
    scheduleRemoteSnapshotFlush()
  }

  public func unregisterWindow(id: Int) {
    windows[id] = nil
    scheduleRemoteSnapshotFlush()
  }

  public func registerTrackedWindow(_ window: RegistryWindow, ownerID: UUID) {
    guard windows[window.id]?.ownership != .manual else {
      return
    }
    windows[window.id] = StoredWindow(window: window, ownership: .tracked(ownerID))
    scheduleRemoteSnapshotFlush()
  }

  public func unregisterTrackedWindow(id: Int, ownerID: UUID) {
    guard windows[id]?.ownership == .tracked(ownerID) else {
      return
    }
    windows[id] = nil
    scheduleRemoteSnapshotFlush()
  }

  public func replaceWindowElements(windowID: Int, elements replacement: [RegistryElement]) {
    clearAllWindowElements(windowID: windowID)
    for element in replacement {
      var normalized = element
      normalized.windowID = windowID
      applyRegisterElement(normalized)
    }
    scheduleRemoteSnapshotFlush()
  }

  public func unregisterElements(windowID: Int) {
    clearAllWindowElements(windowID: windowID)
    scheduleRemoteSnapshotFlush()
  }

  public func replaceTrackedWindowElements(
    windowID: Int,
    elements replacement: [RegistryElement],
    ownerID: UUID
  ) {
    clearTrackedWindowElements(windowID: windowID)

    var identifiers: Set<String> = []
    for element in replacement {
      var normalized = element
      normalized.windowID = windowID
      // Manual MCP-tracked elements are the explicit operator seam. Window
      // snapshots can fill gaps, but they must not clobber those registrations.
      if trackedElementOwners[normalized.identifier] != nil
        || hasExplicitManualOwnership(elements[normalized.identifier]?.ownership)
      {
        continue
      }
      removeTrackedSnapshotReference(for: normalized.identifier)
      elements[normalized.identifier] = StoredElement(
        element: normalized,
        ownership: .trackedWindowSnapshot(windowID: windowID, ownerID: ownerID)
      )
      identifiers.insert(normalized.identifier)
    }

    if identifiers.isEmpty {
      trackedWindowElements[windowID] = nil
    } else {
      trackedWindowElements[windowID] = TrackedWindowElements(
        ownerID: ownerID,
        identifiers: identifiers
      )
    }
    scheduleRemoteSnapshotFlush()
  }

  public func unregisterTrackedWindowElements(windowID: Int, ownerID: UUID) {
    guard trackedWindowElements[windowID]?.ownerID == ownerID else {
      return
    }
    clearTrackedWindowElements(windowID: windowID)
    scheduleRemoteSnapshotFlush()
  }

  public func upsertClientSnapshot(_ clientSnapshot: RegistryClientSnapshot) {
    clientSnapshots[clientSnapshot.clientID] = clientSnapshot
  }

  public func removeClientSnapshot(clientID: UUID) {
    clientSnapshots[clientID] = nil
  }

  public func setRemoteSocketPath(_ socketPath: String?) {
    let previousEndpoint = remoteEndpoint
    guard previousEndpoint?.socketPath != socketPath else {
      if socketPath != nil {
        scheduleRemoteSnapshotFlush()
      }
      return
    }

    remoteEndpoint = socketPath.map(RemoteEndpoint.init(socketPath:))
    if socketPath == nil {
      remoteSnapshotDirty = false
      remoteFlushTask?.cancel()
      remoteFlushTask = nil
      if let previousEndpoint {
        let clientID = clientID
        let remoteSocketClient = remoteSocketClient
        Task.detached(priority: .utility) {
          _ = try? await remoteSocketClient.clearClientSnapshot(
            clientID: clientID,
            toSocketAt: previousEndpoint.socketPath
          )
        }
      }
      return
    }

    scheduleRemoteSnapshotFlush()
  }

  public func element(identifier: String) -> RegistryElement? {
    mergedElementsByIdentifier()[identifier]
  }

  public func allElements(windowID: Int? = nil, kind: RegistryElementKind? = nil) -> [RegistryElement] {
    mergedElements()
      .filter { element in
        if let windowID, element.windowID != windowID { return false }
        if let kind, element.kind != kind { return false }
        return true
      }
      .sorted { $0.identifier < $1.identifier }
  }

  public func allWindows() -> [RegistryWindow] {
    mergedWindows().sorted { $0.id < $1.id }
  }

  public func snapshot() -> RegistrySnapshot {
    RegistrySnapshot(elements: mergedElements(), windows: mergedWindows())
  }

  public func reset() {
    elements.removeAll()
    windows.removeAll()
    trackedWindowElements.removeAll()
    trackedElementOwners.removeAll()
    clientSnapshots.removeAll()
    scheduleRemoteSnapshotFlush()
  }

  private func applyRegisterElement(_ element: RegistryElement) {
    removeTrackedSnapshotReference(for: element.identifier)
    trackedElementOwners[element.identifier] = nil
    elements[element.identifier] = StoredElement(element: element, ownership: .manual)
  }

  private func applyUnregisterElement(identifier: String) {
    removeTrackedSnapshotReference(for: identifier)
    trackedElementOwners[identifier] = nil
    elements[identifier] = nil
  }

  private func applyClaimTrackedElement(identifier: String, ownerID: UUID) {
    trackedElementOwners[identifier] = ownerID
    guard case .trackedWindowSnapshot = elements[identifier]?.ownership else {
      return
    }
    removeTrackedSnapshotReference(for: identifier)
    elements[identifier] = nil
  }

  private func applyRegisterTrackedElement(_ element: RegistryElement, ownerID: UUID) {
    guard trackedElementOwners[element.identifier] == ownerID else {
      return
    }
    removeTrackedSnapshotReference(for: element.identifier)
    elements[element.identifier] = StoredElement(
      element: element,
      ownership: .trackedElement(ownerID: ownerID)
    )
  }

  private func applyClearTrackedElement(identifier: String, ownerID: UUID) {
    guard trackedElementOwners[identifier] == ownerID else {
      return
    }
    clearTrackedElementStorage(identifier: identifier, ownerID: ownerID)
  }

  private func applyUnregisterTrackedElement(identifier: String, ownerID: UUID) {
    guard trackedElementOwners[identifier] == ownerID else {
      return
    }
    trackedElementOwners[identifier] = nil
    clearTrackedElementStorage(identifier: identifier, ownerID: ownerID)
  }

  private func clearTrackedWindowElements(windowID: Int) {
    guard let tracked = trackedWindowElements.removeValue(forKey: windowID) else {
      return
    }
    for identifier in tracked.identifiers {
      guard
        case .trackedWindowSnapshot(let storedWindowID, let storedOwnerID) = elements[identifier]?
          .ownership,
        storedWindowID == windowID,
        storedOwnerID == tracked.ownerID
      else {
        continue
      }

      elements[identifier] = nil
    }
  }

  private func clearAllWindowElements(windowID: Int) {
    let identifiersToRemove = elements.compactMap { identifier, stored in
      stored.element.windowID == windowID ? identifier : nil
    }

    for identifier in identifiersToRemove {
      removeTrackedSnapshotReference(for: identifier)
      elements[identifier] = nil
    }

    trackedWindowElements[windowID] = nil
  }

  private func clearTrackedElementStorage(identifier: String, ownerID: UUID) {
    guard
      case .trackedElement(let storedOwnerID) = elements[identifier]?.ownership,
      storedOwnerID == ownerID
    else {
      return
    }
    elements[identifier] = nil
  }

  private func hasExplicitManualOwnership(_ ownership: ElementOwnership?) -> Bool {
    guard let ownership else {
      return false
    }
    switch ownership {
    case .manual, .trackedElement:
      return true
    case .trackedWindowSnapshot:
      return false
    }
  }

  private func removeTrackedSnapshotReference(for identifier: String) {
    guard
      case .trackedWindowSnapshot(let windowID, let ownerID) = elements[identifier]?.ownership,
      var tracked = trackedWindowElements[windowID]
    else {
      return
    }

    tracked.identifiers.subtract([identifier])
    if tracked.identifiers.isEmpty {
      trackedWindowElements[windowID] = nil
    } else {
      trackedWindowElements[windowID] = TrackedWindowElements(
        ownerID: ownerID,
        identifiers: tracked.identifiers
      )
    }
  }

  private func mergedWindows() -> [RegistryWindow] {
    var merged: [Int: RegistryWindow] = [:]
    for snapshot in clientSnapshots.values.sorted(by: clientSnapshotSort) {
      for window in snapshot.snapshot.windows {
        merged[window.id] = window
      }
    }
    for stored in windows.values {
      merged[stored.window.id] = stored.window
    }
    return Array(merged.values)
  }

  private func mergedElements() -> [RegistryElement] {
    Array(mergedElementsByIdentifier().values)
  }

  private func mergedElementsByIdentifier() -> [String: RegistryElement] {
    var merged: [String: RegistryElement] = [:]
    for snapshot in clientSnapshots.values.sorted(by: clientSnapshotSort) {
      for element in snapshot.snapshot.elements {
        merged[element.identifier] = element
      }
    }
    for stored in elements.values {
      merged[stored.element.identifier] = stored.element
    }
    return merged
  }

  private func scheduleRemoteSnapshotFlush() {
    guard remoteEndpoint != nil else {
      return
    }
    remoteSnapshotDirty = true
    guard remoteFlushTask == nil else {
      return
    }

    let retryDelay = remoteWriteRetryDelay
    let remoteSocketClient = remoteSocketClient
    remoteFlushTask = Task { [weak self] in
      guard let self else {
        return
      }
      while let payload = await self.takeRemoteFlushPayloadOrFinish() {
        let sendSucceeded =
          (try? await remoteSocketClient.syncClientSnapshot(
            payload.snapshot,
            toSocketAt: payload.endpoint.socketPath
          ).applied) != nil
        await self.finishRemoteFlushAttempt(
          socketPath: payload.endpoint.socketPath,
          succeeded: sendSucceeded
        )
        guard sendSucceeded == false else {
          continue
        }
        try? await Task.sleep(for: retryDelay)
      }
    }
  }

  private func takeRemoteFlushPayloadOrFinish() -> RemoteFlushPayload? {
    guard remoteSnapshotDirty, let remoteEndpoint else {
      remoteSnapshotDirty = false
      remoteFlushTask = nil
      return nil
    }

    remoteSnapshotDirty = false
    return RemoteFlushPayload(
      endpoint: remoteEndpoint,
      snapshot: RegistryClientSnapshot(
        clientID: clientID,
        appVersion: clientAppVersion,
        bundleIdentifier: clientBundleIdentifier,
        snapshot: localSnapshot()
      )
    )
  }

  private func finishRemoteFlushAttempt(socketPath: String, succeeded: Bool) {
    guard remoteEndpoint?.socketPath == socketPath else {
      return
    }
    if succeeded == false {
      remoteSnapshotDirty = true
    }
  }

  private func localSnapshot() -> RegistrySnapshot {
    RegistrySnapshot(
      elements: elements.values.map(\.element).sorted { $0.identifier < $1.identifier },
      windows: windows.values.map(\.window).sorted { $0.id < $1.id }
    )
  }
}

public struct RegistrySnapshot: Sendable, Codable, Equatable {
  public let elements: [RegistryElement]
  public let windows: [RegistryWindow]

  public init(elements: [RegistryElement], windows: [RegistryWindow]) {
    self.elements = elements
    self.windows = windows
  }
}

private func clientSnapshotSort(
  lhs: RegistryClientSnapshot,
  rhs: RegistryClientSnapshot
) -> Bool {
  lhs.clientID.uuidString < rhs.clientID.uuidString
}

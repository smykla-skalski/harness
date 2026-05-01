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

  private struct RemoteClearPayload: Equatable {
    let endpoint: RemoteEndpoint
    let clearRequest: RegistryClientClearRequest
  }

  fileprivate struct StoredClientSnapshot {
    let snapshot: RegistryClientSnapshot
    let receivedAt: Date
  }

  private var elements: [String: StoredElement] = [:]
  private var windows: [Int: StoredWindow] = [:]
  private var trackedWindowElements: [Int: TrackedWindowElements] = [:]
  // TrackAccessibility publishes asynchronously, so identifier ownership must be
  // claimed separately from element writes to ignore stale register/unregister tasks.
  private var trackedElementOwners: [String: UUID] = [:]
  private var clientSnapshots: [UUID: StoredClientSnapshot] = [:]
  // Remote publication is latest-wins: local UI churn only needs the newest full
  // snapshot of this process, not every intermediate mutation on the wire.
  private var remoteEndpoint: RemoteEndpoint?
  private var remoteSnapshotDirty = false
  private var remoteFlushTask: Task<Void, Never>?
  private var pendingRemoteClear: RemoteClearPayload?
  private var remoteClearTask: Task<Void, Never>?
  private var remoteHeartbeatTask: Task<Void, Never>?
  private var remoteGeneration: UInt64 = 0

  private let clientID: UUID
  private let clientAppVersion: String
  private let clientBundleIdentifier: String
  private let remoteWriteRetryDelay: Duration
  private let remoteSnapshotLeaseDuration: Duration
  private let remoteHeartbeatInterval: Duration
  private let remoteSocketClient: RegistrySocketClient

  public init(
    clientID: UUID = UUID(),
    clientAppVersion: String = (
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) ?? "0.0.0",
    clientBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.harnessmonitor.app",
    remoteWriteRetryDelay: Duration = .milliseconds(100),
    remoteSnapshotLeaseDuration: Duration = .seconds(2),
    remoteHeartbeatInterval: Duration = .seconds(1),
    remoteSocketClient: RegistrySocketClient = RegistrySocketClient()
  ) {
    self.clientID = clientID
    self.clientAppVersion = clientAppVersion
    self.clientBundleIdentifier = clientBundleIdentifier
    self.remoteWriteRetryDelay = remoteWriteRetryDelay
    self.remoteSnapshotLeaseDuration = remoteSnapshotLeaseDuration
    self.remoteHeartbeatInterval = remoteHeartbeatInterval
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

  public func upsertClientSnapshot(_ clientSnapshot: RegistryClientSnapshot) -> RegistryAckResult {
    pruneExpiredClientSnapshots()
    let normalizedSnapshot = normalizedClientSnapshot(clientSnapshot)
    if let existing = clientSnapshots[normalizedSnapshot.clientID],
      existing.snapshot.generation > normalizedSnapshot.generation
    {
      return RegistryAckResult(
        applied: true,
        message: "ignored stale client snapshot generation \(normalizedSnapshot.generation)"
      )
    }

    clientSnapshots[normalizedSnapshot.clientID] = StoredClientSnapshot(
      snapshot: normalizedSnapshot,
      receivedAt: Date()
    )
    return RegistryAckResult(applied: true)
  }

  public func removeClientSnapshot(_ clearRequest: RegistryClientClearRequest) -> RegistryAckResult {
    pruneExpiredClientSnapshots()
    guard let existing = clientSnapshots[clearRequest.clientID] else {
      return RegistryAckResult(applied: true)
    }
    if existing.snapshot.generation > clearRequest.generation {
      return RegistryAckResult(
        applied: true,
        message: "ignored stale client clear generation \(clearRequest.generation)"
      )
    }
    clientSnapshots[clearRequest.clientID] = nil
    return RegistryAckResult(applied: true)
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
    if let previousEndpoint {
      scheduleRemoteSnapshotClear(for: previousEndpoint)
    }
    if socketPath == nil {
      remoteSnapshotDirty = false
      remoteFlushTask?.cancel()
      remoteFlushTask = nil
      remoteHeartbeatTask?.cancel()
      remoteHeartbeatTask = nil
      return
    }

    startRemoteHeartbeatIfNeeded()
    scheduleRemoteSnapshotFlush()
  }

  public func element(identifier: String) -> RegistryElement? {
    pruneExpiredClientSnapshots()
    return mergedElementsByIdentifier()[identifier]
  }

  public func allElements(windowID: Int? = nil, kind: RegistryElementKind? = nil) -> [RegistryElement] {
    pruneExpiredClientSnapshots()
    return mergedElements()
      .filter { element in
        if let windowID, element.windowID != windowID { return false }
        if let kind, element.kind != kind { return false }
        return true
      }
      .sorted { $0.identifier < $1.identifier }
  }

  public func allWindows() -> [RegistryWindow] {
    pruneExpiredClientSnapshots()
    return mergedWindows().sorted { $0.id < $1.id }
  }

  public func snapshot() -> RegistrySnapshot {
    pruneExpiredClientSnapshots()
    return RegistrySnapshot(elements: mergedElements(), windows: mergedWindows())
  }

  func storedClientSnapshotCount() -> Int {
    pruneExpiredClientSnapshots()
    return clientSnapshots.count
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
    for stored in activeClientSnapshots() {
      for window in stored.snapshot.snapshot.windows {
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
    for stored in activeClientSnapshots() {
      for element in stored.snapshot.snapshot.elements {
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
      while Task.isCancelled == false,
        let payload = await self.takeRemoteFlushPayloadOrFinish()
      {
        let sendSucceeded =
          (try? await remoteSocketClient.syncClientSnapshot(
            payload.snapshot,
            toSocketAt: payload.endpoint.socketPath
          ).applied) == true
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
        generation: takeNextRemoteGeneration(),
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

  private func scheduleRemoteSnapshotClear(for endpoint: RemoteEndpoint) {
    pendingRemoteClear = RemoteClearPayload(
      endpoint: endpoint,
      clearRequest: RegistryClientClearRequest(
        clientID: clientID,
        generation: takeNextRemoteGeneration()
      )
    )
    guard remoteClearTask == nil else {
      return
    }

    let retryDelay = remoteWriteRetryDelay
    let remoteSocketClient = remoteSocketClient
    remoteClearTask = Task { [weak self] in
      guard let self else {
        return
      }
      while Task.isCancelled == false,
        let payload = await self.takeRemoteClearPayloadOrFinish()
      {
        let clearSucceeded =
          (try? await remoteSocketClient.clearClientSnapshot(
            payload.clearRequest,
            toSocketAt: payload.endpoint.socketPath
          ).applied) == true
        await self.finishRemoteClearAttempt(payload, succeeded: clearSucceeded)
        guard clearSucceeded == false else {
          continue
        }
        try? await Task.sleep(for: retryDelay)
      }
    }
  }

  private func takeRemoteClearPayloadOrFinish() -> RemoteClearPayload? {
    guard let pendingRemoteClear else {
      remoteClearTask = nil
      return nil
    }
    return pendingRemoteClear
  }

  private func finishRemoteClearAttempt(_ payload: RemoteClearPayload, succeeded: Bool) {
    guard pendingRemoteClear == payload else {
      return
    }
    if succeeded {
      pendingRemoteClear = nil
    }
  }

  private func startRemoteHeartbeatIfNeeded() {
    guard remoteHeartbeatTask == nil else {
      return
    }

    let heartbeatInterval = remoteHeartbeatInterval
    remoteHeartbeatTask = Task { [weak self] in
      guard let self else {
        return
      }
      while Task.isCancelled == false {
        try? await Task.sleep(for: heartbeatInterval)
        guard Task.isCancelled == false else {
          return
        }
        let shouldContinue = await self.performRemoteHeartbeatTick()
        if shouldContinue == false {
          return
        }
      }
    }
  }

  private func performRemoteHeartbeatTick() -> Bool {
    guard remoteEndpoint != nil else {
      remoteHeartbeatTask = nil
      return false
    }
    scheduleRemoteSnapshotFlush()
    return true
  }

  private func activeClientSnapshots(referenceDate: Date = Date()) -> [StoredClientSnapshot] {
    clientSnapshots.values
      .filter { isClientSnapshotActive($0, referenceDate: referenceDate) }
      .sorted(by: clientSnapshotSort)
  }

  private func pruneExpiredClientSnapshots(referenceDate: Date = Date()) {
    clientSnapshots = clientSnapshots.filter { _, snapshot in
      isClientSnapshotActive(snapshot, referenceDate: referenceDate)
    }
  }

  private func isClientSnapshotActive(
    _ snapshot: StoredClientSnapshot,
    referenceDate: Date
  ) -> Bool {
    referenceDate.timeIntervalSince(snapshot.receivedAt)
      < durationTimeInterval(remoteSnapshotLeaseDuration)
  }

  private func takeNextRemoteGeneration() -> UInt64 {
    remoteGeneration &+= 1
    return remoteGeneration
  }

  private func normalizedClientSnapshot(
    _ clientSnapshot: RegistryClientSnapshot
  ) -> RegistryClientSnapshot {
    RegistryClientSnapshot(
      clientID: clientSnapshot.clientID,
      generation: clientSnapshot.generation,
      appVersion: clientSnapshot.appVersion,
      bundleIdentifier: clientSnapshot.bundleIdentifier,
      snapshot: RegistrySnapshot(
        elements: clientSnapshot.snapshot.elements.map(strippingSemanticActions(from:)),
        windows: clientSnapshot.snapshot.windows
      )
    )
  }

  private func strippingSemanticActions(from element: RegistryElement) -> RegistryElement {
    var stripped = element
    stripped.actions = []
    return stripped
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
  lhs: AccessibilityRegistry.StoredClientSnapshot,
  rhs: AccessibilityRegistry.StoredClientSnapshot
) -> Bool {
  if lhs.receivedAt != rhs.receivedAt {
    return lhs.receivedAt < rhs.receivedAt
  }
  if lhs.snapshot.generation != rhs.snapshot.generation {
    return lhs.snapshot.generation < rhs.snapshot.generation
  }
  return lhs.snapshot.clientID.uuidString < rhs.snapshot.clientID.uuidString
}

private func durationTimeInterval(_ duration: Duration) -> TimeInterval {
  let components = duration.components
  return Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
}

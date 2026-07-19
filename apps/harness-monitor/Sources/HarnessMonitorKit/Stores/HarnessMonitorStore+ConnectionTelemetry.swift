import Foundation

extension HarnessMonitorStore {
  public var connectionState: ConnectionState {
    get { connection.connectionState }
    set {
      let oldValue = connection.connectionState
      connection.connectionState = newValue
      updateDisconnectedSince(from: oldValue, to: newValue)
      guard oldValue != newValue else {
        return
      }
      if newValue == .online {
        dismissDaemonDisconnectDecisionsAfterReconnect()
      }
      #if HARNESS_FEATURE_OTEL
        recordWebSocketConnectionGauge()
      #endif
    }
  }

  public var daemonStatus: DaemonStatusReport? {
    get { connection.daemonStatus }
    set { connection.daemonStatus = newValue }
  }

  public var diagnostics: DaemonDiagnosticsReport? {
    get { connection.diagnostics }
    set { connection.diagnostics = newValue }
  }

  public var health: HealthResponse? {
    get { connection.health }
    set { connection.health = newValue }
  }

  /// Minimum daemon wire version this build of the app is compatible with.
  /// Bumped in lockstep with the daemon's `DAEMON_WIRE_VERSION` when a
  /// breaking schema change ships.
  nonisolated public static let minimumDaemonWireVersion: Int = 2

  /// True when the connected daemon's `wire_version` predates the
  /// [`Self.minimumDaemonWireVersion`] this app expects.
  public var isDaemonWireVersionSkewed: Bool {
    guard let wireVersion = connection.health?.wireVersion else { return false }
    return wireVersion < Self.minimumDaemonWireVersion
  }

  public var isRefreshing: Bool {
    get { connection.isRefreshing }
    set { connection.isRefreshing = newValue }
  }

  public var isDiagnosticsRefreshInFlight: Bool {
    get { connection.isDiagnosticsRefreshInFlight }
    set { connection.isDiagnosticsRefreshInFlight = newValue }
  }

  public var isDaemonActionInFlight: Bool {
    daemonActionCount > 0
  }

  /// Call before starting a daemon-scoped mutation, paired with
  /// `endDaemonAction()` in a `defer`. Counter-backed so concurrent daemon
  /// actions cannot clobber each other's ownership - the first to finish no
  /// longer releases busy state that a still-running second action needs.
  /// `public` because non-`HarnessMonitorKit` conformances (e.g.
  /// `PolicyCanvasEditorRuntime`) drive it through a protocol setter.
  public func beginDaemonAction() {
    daemonActionCount += 1
    if daemonActionCount == 1 {
      scheduleUISync([.contentToolbar, .contentDashboard])
    }
  }

  public func endDaemonAction() {
    guard daemonActionCount > 0 else {
      return
    }
    daemonActionCount -= 1
    if daemonActionCount == 0 {
      scheduleUISync([.contentToolbar, .contentDashboard])
    }
  }

  public var activeTransport: TransportKind {
    get { connection.activeTransport }
    set {
      let oldValue = connection.activeTransport
      connection.activeTransport = newValue
      guard oldValue != newValue else {
        return
      }
      #if HARNESS_FEATURE_OTEL
        recordWebSocketConnectionGauge()
      #endif
    }
  }

  public var connectionMetrics: ConnectionMetrics {
    get { connection.connectionMetrics }
    set { connection.connectionMetrics = newValue }
  }

  public var connectionEvents: [ConnectionEvent] {
    get { connection.connectionEvents }
    set { connection.connectionEvents = newValue }
  }

  public var subscribedSessionIDs: Set<String> {
    get { connection.subscribedSessionIDs }
    set { connection.subscribedSessionIDs = newValue }
  }

  public var daemonLogLevel: String? {
    get { connection.daemonLogLevel }
    set { connection.daemonLogLevel = newValue }
  }

  public var isShowingCachedCatalog: Bool {
    get { connection.isShowingCachedCatalog }
    set { connection.isShowingCachedCatalog = newValue }
  }

  public var isShowingCachedSelectedSession: Bool {
    get { connection.isShowingCachedSelectedSession }
    set { connection.isShowingCachedSelectedSession = newValue }
  }

  public var isShowingCachedData: Bool {
    get { isShowingCachedSelectedSession }
    set { isShowingCachedSelectedSession = newValue }
  }

  public var persistedSessionCount: Int {
    get { connection.persistedSessionCount }
    set { connection.persistedSessionCount = newValue }
  }

  public var lastPersistedSnapshotAt: Date? {
    get { connection.lastPersistedSnapshotAt }
    set { connection.lastPersistedSnapshotAt = newValue }
  }

  public var isBusy: Bool {
    isDaemonActionInFlight || isSessionActionInFlight
  }

  /// True while a task-board-scoped mutation (status move, orchestrator
  /// action, step-mode toggle, dashboard refresh) is in flight. Unlike
  /// `isBusy`, daemon or session actions on other surfaces (reviews,
  /// policies, non-board session actions) do not flip this on, so those
  /// actions no longer visually disable the task board.
  public var isTaskBoardBusy: Bool {
    taskBoardActionCount > 0
  }

  /// Call before starting a task-board mutation, paired with
  /// `endTaskBoardAction()` in a `defer`. Reentrant: nested/concurrent
  /// task-board mutations only flip `isTaskBoardBusy` off once the last one
  /// completes.
  func beginTaskBoardAction() {
    taskBoardActionCount += 1
    if taskBoardActionCount == 1 {
      scheduleUISync([.contentDashboard])
    }
  }

  func endTaskBoardAction() {
    guard taskBoardActionCount > 0 else {
      return
    }
    taskBoardActionCount -= 1
    if taskBoardActionCount == 0 {
      scheduleUISync([.contentDashboard])
    }
  }

  public var isSessionReadOnly: Bool {
    connectionState != .online
  }

  public var sessionCatalogIsEstimated: Bool {
    if case .offline = connectionState {
      return persistedSessionCount > 0 || !sessions.isEmpty
    }
    return isShowingCachedCatalog
  }

  public var sessionDataAvailability: SessionDataAvailability {
    if case .offline(let reason) = connectionState {
      if persistedSessionCount > 0 || !sessions.isEmpty {
        return .persisted(
          reason: .daemonOffline(reason),
          sessionCount: max(persistedSessionCount, sessions.count),
          lastSnapshotAt: lastPersistedSnapshotAt
        )
      }
      return .unavailable(reason: .daemonOffline(reason))
    }

    if isShowingCachedSelectedSession {
      return .persisted(
        reason: .liveDataUnavailable,
        sessionCount: max(persistedSessionCount, sessions.count),
        lastSnapshotAt: lastPersistedSnapshotAt
      )
    }

    return .live
  }

  public var dataReceivedPulse: Bool {
    guard connectionState == .online,
      let lastMessageAt = connectionMetrics.lastMessageAt
    else {
      return false
    }

    return Date.now.timeIntervalSince(lastMessageAt) < 1.5
  }

  public var cachedDataStatusMessage: String {
    if case .offline = connectionState {
      return "Showing cached data - daemon is offline"
    }
    return "Showing cached data - live session detail is unavailable"
  }

  private static let maxLatencySamples = 12
  private static let trafficWindow: TimeInterval = 30

  func resetConnectionMetrics(for transport: TransportKind) {
    guard maintainsLiveDaemonObservation else {
      return
    }
    let disconnectedSince = connectionMetrics.disconnectedSince
    activeTransport = transport
    connectionMetrics = .initial
    connectionMetrics.transportKind = transport
    connectionMetrics.isFallback = transport == .httpSSE
    if connectionState.isSupervisorDisconnectedState {
      connectionMetrics.disconnectedSince = disconnectedSince ?? .now
    }
    transportLatencySamplesMs.removeAll(keepingCapacity: true)
    requestLatencySamplesMs.removeAll(keepingCapacity: true)
    trafficSampleTimes.removeAll(keepingCapacity: true)
  }

  func markConnectionOnline(recordedAt: Date = .now) {
    guard maintainsLiveDaemonObservation else {
      return
    }
    guard connectionMetrics.connectedSince == nil else {
      return
    }
    connectionMetrics.connectedSince = recordedAt
    connectionMetrics.disconnectedSince = nil
    if usesRemoteDaemon {
      stopRemoteDaemonReconnect()
    }
    dismissDaemonDisconnectDecisionsAfterReconnect()
    refreshExternalManifestDiscoveryTask()
  }

  func markConnectionOffline(_ message: String) {
    connectionState = .offline(message)
    stopConnectionProbe()
    connectionMetrics.connectedSince = nil
    connectionMetrics.transportLatencyMs = nil
    connectionMetrics.averageTransportLatencyMs = nil
    connectionMetrics.requestLatencyMs = nil
    connectionMetrics.averageRequestLatencyMs = nil
    connectionMetrics.lastMessageAt = nil
    connectionMetrics.messagesPerSecond = 0
    connectionMetrics.reconnectAttempt = 0
    scheduleSupervisorTick(reason: "connection-offline")
    refreshExternalManifestDiscoveryTask()
  }

  private func updateDisconnectedSince(
    from oldValue: ConnectionState,
    to newValue: ConnectionState
  ) {
    guard newValue.isSupervisorDisconnectedState else {
      connection.connectionMetrics.disconnectedSince = nil
      return
    }
    guard
      !oldValue.isSupervisorDisconnectedState
        || connection.connectionMetrics.disconnectedSince == nil
    else {
      return
    }
    connection.connectionMetrics.disconnectedSince = .now
  }

  func recordRequestSuccess(
    latencyMs: Int? = nil,
    latencySource: ConnectionLatencySource? = nil,
    countsTowardsTraffic: Bool = true,
    recordedAt: Date = .now
  ) {
    guard maintainsLiveDaemonObservation else {
      return
    }
    if let latencyMs, let latencySource {
      updateLatency(latencyMs, source: latencySource)
    }
    guard countsTowardsTraffic else {
      return
    }
    connectionMetrics.messagesSent += 1
    connectionMetrics.messagesReceived += 1
    connectionMetrics.lastMessageAt = recordedAt
    appendTrafficSamples(count: 2, at: recordedAt)
  }

  func recordStreamEvent(
    countedInTraffic: Bool,
    recordedAt: Date = .now
  ) {
    guard maintainsLiveDaemonObservation else {
      return
    }
    connectionMetrics.lastMessageAt = recordedAt
    guard countedInTraffic else {
      return
    }
    connectionMetrics.messagesReceived += 1
    appendTrafficSamples(count: 1, at: recordedAt)
  }

  func recordReconnectAttempt(scope: String, nextAttempt: Int, error: any Error) {
    guard maintainsLiveDaemonObservation else {
      return
    }
    if connectionMetrics.reconnectAttempt == 0 {
      connectionMetrics.reconnectCount += 1
    }
    connectionMetrics.reconnectAttempt = max(connectionMetrics.reconnectAttempt, nextAttempt)
    // Background reconnect: log silently. Surface state through the existing
    // refresh-spinner / SessionDataAvailabilityBanner instead of the toast,
    // which is reserved for explicit user actions.
    let err = error.localizedDescription
    HarnessMonitorLogger.store.warning(
      "reconnecting \(scope, privacy: .public) attempt \(nextAttempt): \(err, privacy: .public)"
    )
    appendConnectionEvent(
      kind: .reconnecting,
      detail: "Reconnecting \(scope) (attempt \(nextAttempt))"
    )
  }

  func recordReconnectRecovery(detail: String) {
    guard maintainsLiveDaemonObservation else {
      return
    }
    guard connectionMetrics.reconnectAttempt > 0 else {
      return
    }
    connectionMetrics.reconnectAttempt = 0
    appendConnectionEvent(kind: .connected, detail: detail)
  }

  private func updateLatency(
    _ latencyMs: Int,
    source: ConnectionLatencySource
  ) {
    switch source {
    case .transport:
      connectionMetrics.transportLatencyMs = latencyMs
      connectionMetrics.averageTransportLatencyMs = appendLatencySample(
        latencyMs,
        to: &transportLatencySamplesMs
      )
    case .request:
      connectionMetrics.requestLatencyMs = latencyMs
      connectionMetrics.averageRequestLatencyMs = appendLatencySample(
        latencyMs,
        to: &requestLatencySamplesMs
      )
    }
  }

  private func appendLatencySample(
    _ latencyMs: Int,
    to samples: inout [Int]
  ) -> Int {
    samples.append(latencyMs)
    if samples.count > Self.maxLatencySamples {
      samples.removeFirst(samples.count - Self.maxLatencySamples)
    }
    let total = samples.reduce(0, +)
    return total / max(samples.count, 1)
  }

  private func appendTrafficSamples(count: Int, at timestamp: Date) {
    for _ in 0..<count {
      trafficSampleTimes.append(timestamp)
    }
    let threshold = timestamp.addingTimeInterval(-Self.trafficWindow)
    trafficSampleTimes.removeAll { $0 < threshold }
    connectionMetrics.messagesPerSecond = Double(trafficSampleTimes.count) / Self.trafficWindow
  }
}

import Foundation

extension HarnessMonitorStore {
  public enum PersistedSessionReason: Equatable {
    case daemonOffline(String)
    case liveDataUnavailable
  }

  public enum SessionDataAvailability: Equatable {
    case live
    case persisted(
      reason: PersistedSessionReason,
      sessionCount: Int,
      lastSnapshotAt: Date?
    )
    case unavailable(reason: PersistedSessionReason)
  }

  public var connectionState: ConnectionState {
    get { connection.connectionState }
    set { connection.connectionState = newValue }
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

  public var isRefreshing: Bool {
    get { connection.isRefreshing }
    set { connection.isRefreshing = newValue }
  }

  public var isDiagnosticsRefreshInFlight: Bool {
    get { connection.isDiagnosticsRefreshInFlight }
    set { connection.isDiagnosticsRefreshInFlight = newValue }
  }

  public var isDaemonActionInFlight: Bool {
    get { connection.isDaemonActionInFlight }
    set { connection.isDaemonActionInFlight = newValue }
  }

  public var activeTransport: TransportKind {
    get { connection.activeTransport }
    set { connection.activeTransport = newValue }
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

  public var isShowingCachedData: Bool {
    get { connection.isShowingCachedData }
    set { connection.isShowingCachedData = newValue }
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

  public var isSessionReadOnly: Bool {
    connectionState != .online
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

    if isShowingCachedData {
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

  struct MeasuredOperation<Value: Sendable>: Sendable {
    let value: Value
    let latencyMs: Int
  }

  nonisolated static func measureOperation<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> MeasuredOperation<Value> {
    let startedAt = ContinuousClock.now
    let value = try await operation()
    let duration = startedAt.duration(to: ContinuousClock.now)
    return MeasuredOperation(
      value: value,
      latencyMs: max(0, Int(duration.components.seconds * 1_000))
        + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    )
  }

  func resetConnectionMetrics(for transport: TransportKind) {
    activeTransport = transport
    connectionMetrics = .initial
    connectionMetrics.transportKind = transport
    connectionMetrics.connectedSince = .now
    connectionMetrics.isFallback = transport == .httpSSE
    latencySamplesMs.removeAll(keepingCapacity: true)
    trafficSampleTimes.removeAll(keepingCapacity: true)
  }

  func markConnectionOffline(_ message: String) {
    connectionState = .offline(message)
    lastError = message
    stopConnectionProbe()
    connectionMetrics.connectedSince = nil
    connectionMetrics.latencyMs = nil
    connectionMetrics.lastMessageAt = nil
    connectionMetrics.messagesPerSecond = 0
    connectionMetrics.reconnectAttempt = 0
  }

  func recordRequestSuccess(
    latencyMs: Int? = nil,
    updatesLatency: Bool = false,
    countsTowardsTraffic: Bool = true,
    recordedAt: Date = .now
  ) {
    if updatesLatency, let latencyMs {
      updateLatency(latencyMs)
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
    connectionMetrics.lastMessageAt = recordedAt
    guard countedInTraffic else {
      return
    }
    connectionMetrics.messagesReceived += 1
    appendTrafficSamples(count: 1, at: recordedAt)
  }

  func recordReconnectAttempt(scope: String, nextAttempt: Int, error: any Error) {
    if connectionMetrics.reconnectAttempt == 0 {
      connectionMetrics.reconnectCount += 1
    }
    connectionMetrics.reconnectAttempt = max(connectionMetrics.reconnectAttempt, nextAttempt)
    lastError = error.localizedDescription
    appendConnectionEvent(
      kind: .reconnecting,
      detail: "Reconnecting \(scope) (attempt \(nextAttempt))"
    )
  }

  func recordReconnectRecovery(detail: String) {
    guard connectionMetrics.reconnectAttempt > 0 else {
      return
    }
    connectionMetrics.reconnectAttempt = 0
    appendConnectionEvent(kind: .connected, detail: detail)
  }

  func startConnectionProbe(using client: any HarnessMonitorClientProtocol) {
    stopConnectionProbe()
    connectionProbeTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      var consecutiveFailures = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: connectionProbeInterval)
        guard !Task.isCancelled else {
          return
        }
        guard connectionState == .online, !isRefreshing, !isSessionActionInFlight else {
          continue
        }

        do {
          if let transportLatencyMs = try await client.transportLatencyMs() {
            consecutiveFailures = 0
            recordRequestSuccess(
              latencyMs: transportLatencyMs,
              updatesLatency: true,
              countsTowardsTraffic: false
            )
            continue
          }
          let sample = try await Self.measureOperation {
            try await client.health()
          }
          consecutiveFailures = 0
          recordRequestSuccess(
            latencyMs: sample.latencyMs,
            updatesLatency: true,
            countsTowardsTraffic: false
          )
        } catch {
          if Task.isCancelled {
            return
          }
          consecutiveFailures += 1
          appendConnectionEvent(
            kind: .error,
            detail: "Latency probe failed: \(error.localizedDescription)"
          )

          if consecutiveFailures >= 2 {
            appendConnectionEvent(
              kind: .reconnecting,
              detail: "Probe failed \(consecutiveFailures) times, re-bootstrapping"
            )
            await reconnect()
            return
          }
        }
      }
    }
  }

  func stopConnectionProbe() {
    connectionProbeTask?.cancel()
    connectionProbeTask = nil
  }

  private func updateLatency(_ latencyMs: Int) {
    connectionMetrics.latencyMs = latencyMs
    latencySamplesMs.append(latencyMs)
    if latencySamplesMs.count > Self.maxLatencySamples {
      latencySamplesMs.removeFirst(latencySamplesMs.count - Self.maxLatencySamples)
    }
    let total = latencySamplesMs.reduce(0, +)
    connectionMetrics.averageLatencyMs = total / max(latencySamplesMs.count, 1)
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

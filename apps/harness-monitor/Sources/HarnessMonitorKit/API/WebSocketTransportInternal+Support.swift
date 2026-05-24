import Foundation

extension WebSocketTransport {
  private struct ClientHandshakeMetadata {
    let name: String
    let version: String
    let bundleIdentifier: String
    let processIdentifier: Int32
    let launchMode: String

    var userAgent: String {
      "HarnessMonitor/\(version) "
        + "(bundle=\(bundleIdentifier); pid=\(processIdentifier); launch=\(launchMode))"
    }

    var logIdentity: String {
      "\(name)/\(version) "
        + "(bundle=\(bundleIdentifier); pid=\(processIdentifier); launch=\(launchMode))"
    }

    var headers: [String: String] {
      [
        "User-Agent": userAgent,
        WebSocketTransport.clientNameHeaderField: name,
        WebSocketTransport.clientVersionHeaderField: version,
        WebSocketTransport.clientBundleIDHeaderField: bundleIdentifier,
        WebSocketTransport.clientPIDHeaderField: String(processIdentifier),
        WebSocketTransport.clientLaunchModeHeaderField: launchMode,
      ]
    }
  }

  private static let clientNameHeaderField = "X-Harness-Client-Name"
  private static let clientVersionHeaderField = "X-Harness-Client-Version"
  private static let clientBundleIDHeaderField = "X-Harness-Client-Bundle-ID"
  private static let clientPIDHeaderField = "X-Harness-Client-PID"
  private static let clientLaunchModeHeaderField = "X-Harness-Client-Launch-Mode"
  private static let defaultClientName = "harness-monitor"
  private static let defaultClientVersion = "0.0.0"
  private static let defaultClientBundleID = "io.harnessmonitor.app"

  func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self else { break }
        try? await self.sendPing()
      }
    }
  }

  func terminateAllStreams() {
    clearPendingAcpEventPushes()
    globalStreamContinuation?.finish()
    globalStreamContinuation = nil
    for (_, continuation) in sessionStreamContinuations {
      continuation.finish()
    }
    sessionStreamContinuations.removeAll()
    responseBatchHandlers.removeAll()
    partialFrames.removeAll()
  }

  func cancelWebSocketTaskIfNeeded(closeCode: URLSessionWebSocketTask.CloseCode) {
    guard let webSocketTask else {
      return
    }

    guard webSocketTask.state == .running, webSocketTask.closeCode == .invalid else {
      return
    }

    webSocketTask.cancel(with: closeCode, reason: nil)
  }

  /// Drops the dead `webSocketTask` after a receive-loop failure. Does not
  /// call `cancel()`: the underlying socket is already gone, and writing a
  /// close frame to it would log a spurious
  /// `nw_socket_output_finished … shutdown(21, SHUT_WR)` warning. Letting
  /// ARC release the reference is enough — the URLSession task is already
  /// terminal from URLSession's point of view. Subsequent `rpc()` and
  /// `sendPing()` calls trip the `guard let webSocketTask else { throw … }`
  /// path and fail-fast instead of queueing into the dead socket.
  func releaseDeadWebSocketTask() {
    webSocketTask = nil
  }

  func applyHandshakeHeaders(to request: inout URLRequest) {
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    for (field, value) in currentClientHandshakeMetadata().headers {
      request.setValue(value, forHTTPHeaderField: field)
    }
  }

  nonisolated func currentClientLogIdentity() -> String {
    currentClientHandshakeMetadata().logIdentity
  }

  nonisolated static func makeClientMetadataHeaders(
    bundleIdentifier: String?,
    appVersion: String?,
    processIdentifier: Int32,
    environment: [String: String]
  ) -> [String: String] {
    makeClientHandshakeMetadata(
      bundleIdentifier: bundleIdentifier,
      appVersion: appVersion,
      processIdentifier: processIdentifier,
      environment: environment
    ).headers
  }

  nonisolated static func makeClientLogIdentity(
    bundleIdentifier: String?,
    appVersion: String?,
    processIdentifier: Int32,
    environment: [String: String]
  ) -> String {
    makeClientHandshakeMetadata(
      bundleIdentifier: bundleIdentifier,
      appVersion: appVersion,
      processIdentifier: processIdentifier,
      environment: environment
    ).logIdentity
  }

  nonisolated private static func resolvedClientValue(
    _ value: String?,
    defaultValue: String
  ) -> String {
    guard let value else {
      return defaultValue
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? defaultValue : trimmed
  }

  nonisolated private func currentClientHandshakeMetadata() -> ClientHandshakeMetadata {
    Self.makeClientHandshakeMetadata(
      bundleIdentifier: Bundle.main.bundleIdentifier,
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      processIdentifier: ProcessInfo.processInfo.processIdentifier,
      environment: ProcessInfo.processInfo.environment
    )
  }

  nonisolated private static func makeClientHandshakeMetadata(
    bundleIdentifier: String?,
    appVersion: String?,
    processIdentifier: Int32,
    environment: [String: String]
  ) -> ClientHandshakeMetadata {
    let resolvedBundleIdentifier = resolvedClientValue(
      bundleIdentifier,
      defaultValue: defaultClientBundleID
    )
    let resolvedVersion = resolvedClientValue(
      appVersion,
      defaultValue: defaultClientVersion
    )
    let launchMode = HarnessMonitorLaunchMode(environment: environment).rawValue

    return ClientHandshakeMetadata(
      name: defaultClientName,
      version: resolvedVersion,
      bundleIdentifier: resolvedBundleIdentifier,
      processIdentifier: processIdentifier,
      launchMode: launchMode
    )
  }

  nonisolated func wsEndpoint() -> URL {
    guard
      var components = URLComponents(
        url: connection.endpoint,
        resolvingAgainstBaseURL: false
      )
    else {
      return connection.endpoint
    }
    components.scheme = connection.endpoint.scheme == "https" ? "wss" : "ws"
    components.path = "/v1/ws"
    return components.url ?? connection.endpoint
  }

  private static let reencodeEncoder = JSONEncoder()
  private static let mergeDecoder = JSONDecoder()

  nonisolated func decode<T: Decodable>(_ value: JSONValue) throws -> T {
    let data = try Self.reencodeEncoder.encode(value)
    return try decoder.decode(T.self, from: data)
  }

  nonisolated func encodeParams<T: Encodable>(
    _ body: T,
    extra: [String: JSONValue]
  ) throws -> JSONValue {
    let data = try encoder.encode(body)
    guard
      var object = try JSONSerialization.jsonObject(with: data)
        as? [String: Any]
    else {
      return .null
    }
    for (key, value) in extra {
      if case .string(let stringValue) = value {
        object[key] = stringValue
      }
    }
    let merged = try JSONSerialization.data(withJSONObject: object)
    return try Self.mergeDecoder.decode(JSONValue.self, from: merged)
  }

  func handleConfigurationPush(payload: JSONValue) {
    do {
      let configuration: MonitorConfiguration = try decode(payload)
      cachedConfiguration = configuration
      let waiters = configurationWaiters
      configurationWaiters.removeAll()
      for waiter in waiters {
        waiter.resume(returning: configuration)
      }
    } catch {
      let err = error.localizedDescription
      HarnessMonitorLogger.websocket.warning(
        "Dropping malformed config push frame: \(err, privacy: .public)"
      )
    }
  }

  func finishStreams(with error: any Error) {
    globalStreamContinuation?.finish(throwing: error)
    globalStreamContinuation = nil
    for (_, continuation) in sessionStreamContinuations {
      continuation.finish(throwing: error)
    }
    sessionStreamContinuations.removeAll()
  }

  func deliverPushFrame(
    event: String,
    recordedAt: String,
    sessionId: String?,
    payload: JSONValue
  ) async {
    let streamEvent = StreamEvent(
      event: event,
      recordedAt: recordedAt,
      sessionId: sessionId,
      payload: payload
    )
    do {
      let pushEvent = try DaemonPushEvent(streamEvent: streamEvent)
      deliverPushEvent(pushEvent)
    } catch {
      let err = error.localizedDescription
      enqueueDecodeFailureTelemetry(
        source: "swift.websocket.push",
        message: "Push frame \(event) decode failed: \(String(reflecting: error))",
        sample: encodedTelemetrySample(from: payload)
      )
      HarnessMonitorLogger.websocket.warning(
        "Dropping malformed push frame \(event, privacy: .public): \(err, privacy: .public)"
      )
    }
  }

  func deliverPushEvent(_ pushEvent: DaemonPushEvent) {
    globalStreamContinuation?.yield(pushEvent)
    if let sessionId = pushEvent.sessionId,
      let continuation = sessionStreamContinuations[sessionId]
    {
      continuation.yield(pushEvent)
    }
  }

  func enqueueAcpEventPush(
    recordedAt: String,
    sessionId: String?,
    payload: JSONValue
  ) async {
    guard let sessionId else {
      HarnessMonitorLogger.websocket.warning(
        "Dropping malformed push frame acp_events: missing session id"
      )
      return
    }
    do {
      let batch: AcpEventBatchPayload = try decode(payload)
      guard batch.sessionId == sessionId else {
        HarnessMonitorLogger.websocket.warning(
          """
          Dropping malformed push frame acp_events: payload session id \
          \(batch.sessionId, privacy: .public) did not match frame session id \
          \(sessionId, privacy: .public)
          """
        )
        return
      }
      let key = PendingAcpEventPushKey(sessionId: sessionId, acpId: batch.acpId)
      if var pendingBatch = pendingAcpEventPushes[key] {
        pendingBatch.merge(
          recordedAt: recordedAt,
          payload: batch,
          maxRetainedEvents: Self.maxCoalescedAcpEvents
        )
        pendingAcpEventPushes[key] = pendingBatch
      } else {
        pendingAcpEventPushes[key] = PendingAcpEventPushBatch(
          recordedAt: recordedAt,
          payload: batch,
          maxRetainedEvents: Self.maxCoalescedAcpEvents
        )
        pendingAcpEventPushOrder.append(key)
      }
      schedulePendingAcpEventFlushIfNeeded()
    } catch {
      enqueueDecodeFailureTelemetry(
        source: "swift.websocket.acp_events",
        message: "ACP event push decode failed: \(String(reflecting: error))",
        sample: encodedTelemetrySample(from: payload)
      )
      HarnessMonitorLogger.websocket.warning(
        """
        Dropping malformed push frame acp_events: \(error.localizedDescription, privacy: .public)
        """
      )
    }
  }

  func schedulePendingAcpEventFlushIfNeeded() {
    guard acpEventAutoFlushEnabled else {
      return
    }
    guard pendingAcpEventFlushTask == nil else {
      return
    }
    pendingAcpEventFlushTask = Task { [weak self] in
      await Task.yield()
      await self?.flushPendingAcpEventPushes()
    }
  }

  func flushPendingAcpEventPushes() {
    pendingAcpEventFlushTask = nil
    let pendingKeys = pendingAcpEventPushOrder
    pendingAcpEventPushOrder.removeAll()
    let pendingBatches = pendingKeys.compactMap { key in
      pendingAcpEventPushes.removeValue(forKey: key)
    }
    let overflowedBatches = pendingBatches.filter { $0.droppedRawCount > 0 }
    if !overflowedBatches.isEmpty {
      acpOverflowLogBurstCount += 1
      HarnessMonitorLogger.websocket.info(
        """
        ACP event coalescer overflowed across \(overflowedBatches.count) pending batches; \
        retained \(overflowedBatches.reduce(0) { $0 + $1.payload.events.count }) events from \
        \(overflowedBatches.reduce(0) { $0 + $1.rawCount }) raw updates and dropped \
        \(overflowedBatches.reduce(0) { $0 + $1.droppedRawCount }) oldest raw updates before flush. \
        Widening review required.
        """
      )
    }
    for batch in pendingBatches {
      deliverPushEvent(
        DaemonPushEvent(
          recordedAt: batch.recordedAt,
          sessionId: batch.sessionId,
          kind: .acpEvents(batch.payload)
        )
      )
    }
  }

  func clearPendingAcpEventPushes() {
    pendingAcpEventFlushTask?.cancel()
    pendingAcpEventFlushTask = nil
    pendingAcpEventPushes.removeAll()
    pendingAcpEventPushOrder.removeAll()
  }

  func acpOverflowLogBurstCountForTests() -> Int {
    acpOverflowLogBurstCount
  }

  func setAcpEventAutoFlushEnabledForTests(_ enabled: Bool) {
    acpEventAutoFlushEnabled = enabled
  }

  func enqueueDecodeFailureTelemetry(
    source: String,
    message: String,
    sample: String?
  ) {
    let telemetryRequest = DaemonTelemetryRequest(
      kind: .decodeFailure,
      source: source,
      message: message,
      sample: sample
    )
    do {
      let url = URL(
        string: DaemonTelemetrySupport.path,
        relativeTo: connection.endpoint
      )
      guard let url else {
        throw HarnessMonitorAPIError.invalidEndpoint(connection.endpoint.absoluteString)
      }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.timeoutInterval = DaemonTelemetrySupport.requestTimeoutInterval
      request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.httpBody = try encoder.encode(AnyEncodable(telemetryRequest))
      let session = self.session
      Task.detached(priority: .utility) {
        await Self.sendDecodeFailureTelemetry(request: request, session: session)
      }
    } catch {
      HarnessMonitorLogger.websocket.warning(
        """
        Failed to record decode-failure telemetry: \
        \(error.localizedDescription, privacy: .public)
        """
      )
    }
  }

  private static func sendDecodeFailureTelemetry(
    request: URLRequest,
    session: URLSession
  ) async {
    do {
      let (_, response) = try await session.data(for: request)
      if let httpResponse = response as? HTTPURLResponse,
        !(200..<300).contains(httpResponse.statusCode)
      {
        HarnessMonitorLogger.websocket.warning(
          """
          Decode-failure telemetry was rejected: \
          \(httpResponse.statusCode, privacy: .public)
          """
        )
      }
    } catch {
      HarnessMonitorLogger.websocket.warning(
        """
        Failed to record decode-failure telemetry: \
        \(error.localizedDescription, privacy: .public)
        """
      )
    }
  }

  nonisolated func encodedTelemetrySample(from payload: JSONValue) -> String? {
    guard let data = try? Self.reencodeEncoder.encode(payload) else {
      return nil
    }
    return DaemonTelemetrySupport.truncatedSample(data)
  }
}

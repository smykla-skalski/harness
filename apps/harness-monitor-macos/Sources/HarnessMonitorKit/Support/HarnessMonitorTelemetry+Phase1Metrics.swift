import OpenTelemetryApi

extension HarnessMonitorTelemetry {
  @discardableResult
  public func withAppLifecycleTransition<T>(
    event: String,
    launchMode: String,
    _ operation: () throws -> T
  ) rethrows -> T {
    let span = startSpan(
      name: appLifecycleSpanName(for: event),
      kind: .internal,
      attributes: ["app.launch_mode": .string(launchMode)]
    )
    recordAppLifecycleEvent(event: event, launchMode: launchMode, durationMs: nil)
    defer { span.end() }
    return try withActiveSpan(span, operation)
  }

  public func recordAppLifecycleEvent(event: String, launchMode: String, durationMs: Double?) {
    bootstrap()
    let instruments = stateLock.withLock { state.instruments }
    instruments?.recordAppLifecycleEvent(
      event: event,
      launchMode: launchMode,
      durationMs: durationMs
    )
  }

  func recordUserInteraction(interaction: String, sessionID: String?, durationMs: Double) {
    bootstrap()
    let instruments = stateLock.withLock { state.instruments }
    instruments?.recordUserInteraction(
      interaction: interaction,
      sessionID: sessionID,
      durationMs: durationMs
    )
  }

  func recordCacheRead(operation: String, hit: Bool, durationMs: Double) {
    bootstrap()
    let instruments = stateLock.withLock { state.instruments }
    instruments?.recordCacheRead(
      operation: operation,
      hit: hit,
      durationMs: durationMs
    )
  }

  func recordResourceMetrics(residentMemoryBytes: Int64, virtualMemoryBytes: Int64) {
    bootstrap()
    let instruments = stateLock.withLock { state.instruments }
    instruments?.recordResourceMetrics(
      residentMemoryBytes: residentMemoryBytes,
      virtualMemoryBytes: virtualMemoryBytes
    )
  }

  func recordActiveTasks(_ count: Int) {
    bootstrap()
    let instruments = stateLock.withLock { state.instruments }
    instruments?.recordActiveTasks(count)
  }

  func recordWebSocketConnections(_ count: Int) {
    bootstrap()
    let instruments = stateLock.withLock { state.instruments }
    instruments?.recordWebSocketConnections(count)
  }

  func recordAPIError(endpoint: String, method: String, errorType: String, statusCode: Int?) {
    bootstrap()
    let instruments = stateLock.withLock { state.instruments }
    instruments?.recordAPIError(
      endpoint: endpoint,
      method: method,
      errorType: errorType,
      statusCode: statusCode
    )
  }

  func recordDecodingError(entity: String, reason: String) {
    bootstrap()
    let instruments = stateLock.withLock { state.instruments }
    instruments?.recordDecodingError(entity: entity, reason: reason)
  }

  func recordTimeoutError(operation: String, durationMs: Double) {
    bootstrap()
    let instruments = stateLock.withLock { state.instruments }
    instruments?.recordTimeoutError(operation: operation, durationMs: durationMs)
  }

  private func appLifecycleSpanName(for event: String) -> String {
    switch event {
    case "become_active":
      "app.lifecycle.active"
    default:
      "app.lifecycle.\(event)"
    }
  }
}

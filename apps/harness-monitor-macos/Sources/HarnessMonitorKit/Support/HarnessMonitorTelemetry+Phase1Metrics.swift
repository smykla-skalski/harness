import OpenTelemetryApi

extension HarnessMonitorTelemetry {
  func recordAppLifecycleEvent(event: String, launchMode: String, durationMs: Double?) {
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
}

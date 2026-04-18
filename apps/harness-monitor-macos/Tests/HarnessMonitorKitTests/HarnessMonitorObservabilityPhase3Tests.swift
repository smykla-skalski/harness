import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor observability Phase 3 cache and resource metrics")
struct HarnessMonitorObservabilityPhase3Tests {

  // MARK: - Cache Read Instrumentation

  @Test("Cache read records hit metric")
  func cacheReadRecordsHitMetric() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "load_session_detail",
      hit: true,
      durationMs: 5.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_cache_hits_total"))
  }

  @Test("Cache read records miss metric")
  func cacheReadRecordsMissMetric() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "load_session_detail",
      hit: false,
      durationMs: 10.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_cache_misses_total"))
  }

  @Test("Cache read records duration histogram")
  func cacheReadRecordsDurationHistogram() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "load_session_list",
      hit: true,
      durationMs: 25.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_cache_read_duration_ms"))
  }

  @Test("Cache operation includes operation attribute")
  func cacheOperationIncludesOperationAttribute() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "hydration_queue",
      hit: true,
      durationMs: 15.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_cache_hits_total"
    )
    let hasOperation = dataPoints.contains { dp in
      dp.attributes["cache.operation"] == "hydration_queue"
    }
    #expect(hasOperation)
  }

  // MARK: - Resource Metrics

  @Test("Resource metrics records memory gauges")
  func resourceMetricsRecordsMemoryGauges() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordResourceMetrics(
      residentMemoryBytes: 50_000_000,
      virtualMemoryBytes: 200_000_000
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_memory_resident_bytes"))
    #expect(metricNames.contains("harness_monitor_memory_virtual_bytes"))
  }

  // MARK: - API Error Metrics

  @Test("API error records counter with error type")
  func apiErrorRecordsCounterWithErrorType() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordAPIError(
      endpoint: "/v1/sessions",
      method: "GET",
      errorType: "timeout",
      statusCode: nil
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_api_errors_total"))

    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_api_errors_total"
    )
    let hasErrorType = dataPoints.contains { dp in
      dp.attributes["error.type"] == "timeout"
    }
    #expect(hasErrorType)
  }

  @Test("Decoding error records counter with entity")
  func decodingErrorRecordsCounterWithEntity() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordDecodingError(
      entity: "SessionDetail",
      reason: "keyNotFound"
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_decoding_errors_total"))

    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_decoding_errors_total"
    )
    let hasEntity = dataPoints.contains { dp in
      dp.attributes["error.entity"] == "SessionDetail"
    }
    #expect(hasEntity)
  }

  @Test("Timeout error records counter with operation")
  func timeoutErrorRecordsCounterWithOperation() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordTimeoutError(
      operation: "http_request",
      durationMs: 30000.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_timeout_errors_total"))

    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_timeout_errors_total"
    )
    let hasOperation = dataPoints.contains { dp in
      dp.attributes["timeout.operation"] == "http_request"
    }
    #expect(hasOperation)
  }
}

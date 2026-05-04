import Foundation
import XCTest

@testable import HarnessMonitorKit

final class HarnessMonitorObservabilityPhase3Tests: XCTestCase {

  private static var _server: GRPCCollectorServer!
  private static var _temporaryHome: URL!
  private static var _environment: HarnessMonitorEnvironment!

  private var collector: GRPCCollectorServer { Self._server }

  override class func setUp() {
    super.setUp()
    _server = try! GRPCCollectorServer()
    (_temporaryHome, _environment) = try! makeTestEnvironment(collector: _server)
  }

  override class func tearDown() {
    _server.shutdown()
    try? FileManager.default.removeItem(at: _temporaryHome)
    super.tearDown()
  }

  override func setUp() {
    super.setUp()
    collector.resetAllCollectors()
    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: Self._environment)
  }

  // MARK: - Cache Read Instrumentation

  func testCacheReadRecordsHitMetric() async throws {
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "load_session_detail", hit: true, durationMs: 5.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      self.collector.metricCollector.hasReceivedMetrics
    }

    XCTAssertTrue(
      collector.metricCollector.metricNames.contains("harness_monitor_cache_hits_total")
    )
  }

  func testCacheReadRecordsMissMetric() async throws {
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "load_session_detail", hit: false, durationMs: 10.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      self.collector.metricCollector.hasReceivedMetrics
    }

    XCTAssertTrue(
      collector.metricCollector.metricNames.contains("harness_monitor_cache_misses_total")
    )
  }

  func testCacheReadRecordsDurationHistogram() async throws {
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "load_session_list", hit: true, durationMs: 25.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      self.collector.metricCollector.hasReceivedMetrics
    }

    XCTAssertTrue(
      collector.metricCollector.metricNames.contains("harness_monitor_cache_read_duration_ms")
    )
  }

  func testCacheOperationIncludesOperationAttribute() async throws {
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "hydration_queue", hit: true, durationMs: 15.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      self.collector.metricCollector.hasReceivedMetrics
    }

    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_cache_hits_total"
    )
    XCTAssertTrue(dataPoints.contains { $0.attributes["cache.operation"] == "hydration_queue" })
  }

  // MARK: - Resource Metrics

  func testResourceMetricsRecordsMemoryGauges() async throws {
    HarnessMonitorTelemetry.shared.recordResourceMetrics(
      residentMemoryBytes: 50_000_000, virtualMemoryBytes: 200_000_000
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      self.collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    XCTAssertTrue(metricNames.contains("harness_monitor_memory_resident_bytes"))
    XCTAssertTrue(metricNames.contains("harness_monitor_memory_virtual_bytes"))
  }

  // MARK: - API Error Metrics

  func testAPIErrorRecordsCounterWithErrorType() async throws {
    HarnessMonitorTelemetry.shared.recordAPIError(
      endpoint: "/v1/sessions", method: "GET", errorType: "timeout", statusCode: nil
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      self.collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    XCTAssertTrue(metricNames.contains("harness_monitor_api_errors_total"))
    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_api_errors_total"
    )
    XCTAssertTrue(dataPoints.contains { $0.attributes["error.type"] == "timeout" })
  }

  func testDecodingErrorRecordsCounterWithEntity() async throws {
    HarnessMonitorTelemetry.shared.recordDecodingError(
      entity: "SessionDetail", reason: "keyNotFound"
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      self.collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    XCTAssertTrue(metricNames.contains("harness_monitor_decoding_errors_total"))
    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_decoding_errors_total"
    )
    XCTAssertTrue(dataPoints.contains { $0.attributes["error.entity"] == "SessionDetail" })
  }

  func testTimeoutErrorRecordsCounterWithOperation() async throws {
    HarnessMonitorTelemetry.shared.recordTimeoutError(
      operation: "http_request", durationMs: 30000.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      self.collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    XCTAssertTrue(metricNames.contains("harness_monitor_timeout_errors_total"))
    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_timeout_errors_total"
    )
    XCTAssertTrue(dataPoints.contains { $0.attributes["timeout.operation"] == "http_request" })
  }
}

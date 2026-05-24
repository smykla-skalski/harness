import Foundation
import XCTest

@testable import HarnessMonitorKit

class HarnessMonitorObservabilityPhase1Tests: XCTestCase {

  private static var _server: GRPCCollectorServer!
  private static var _temporaryHome: URL!
  private static var _environment: HarnessMonitorEnvironment!

  private var collector: GRPCCollectorServer { Self._server }

  override class func setUp() {
    super.setUp()
    do {
      _server = try GRPCCollectorServer()
      (_temporaryHome, _environment) = try makeTestEnvironment(collector: _server)
    } catch {
      fatalError("Failed to initialize observability phase 1 fixtures: \(error)")
    }
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

  // MARK: - App Lifecycle

  func testAppLifecycleCounterIncrementsOnEvent() {
    HarnessMonitorTelemetry.shared.recordAppLifecycleEvent(
      event: "bootstrap", launchMode: "live", durationMs: 150.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let metricNames = collector.metricCollector.metricNames
    XCTAssertTrue(metricNames.contains("harness_monitor_app_lifecycle_total"))
    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_app_lifecycle_total"
    )
    XCTAssertTrue(dataPoints.contains { $0.attributes["app.lifecycle.event"] == "bootstrap" })
  }

  func testAppBootstrapDurationRecordsHistogram() {
    HarnessMonitorTelemetry.shared.recordAppLifecycleEvent(
      event: "bootstrap", launchMode: "live", durationMs: 250.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    XCTAssertTrue(
      collector.metricCollector.metricNames.contains("harness_monitor_bootstrap_duration_ms")
    )
  }

  // MARK: - User Interactions

  func testUserInteractionCounterIncrementsWithAttributes() {
    HarnessMonitorTelemetry.shared.recordUserInteraction(
      interaction: "select_session", sessionID: "test-session-123", durationMs: 45.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let metricNames = collector.metricCollector.metricNames
    XCTAssertTrue(metricNames.contains("harness_monitor_user_interactions_total"))
    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_user_interactions_total"
    )
    XCTAssertTrue(
      dataPoints.contains { $0.attributes["user.interaction.type"] == "select_session" }
    )
  }

  // MARK: - Cache Observability

  func testCacheHitCounterIncrementsOnHit() {
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "load_session_detail", hit: true, durationMs: 2.5
    )
    HarnessMonitorTelemetry.shared.shutdown()

    XCTAssertTrue(
      collector.metricCollector.metricNames.contains("harness_monitor_cache_hits_total")
    )
  }

  func testCacheMissCounterIncrementsOnMiss() {
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "load_session_detail", hit: false, durationMs: 3.2
    )
    HarnessMonitorTelemetry.shared.shutdown()

    XCTAssertTrue(
      collector.metricCollector.metricNames.contains("harness_monitor_cache_misses_total")
    )
  }

  func testCacheReadDurationRecordsLatency() {
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "load_session_list", hit: true, durationMs: 5.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    XCTAssertTrue(
      collector.metricCollector.metricNames.contains("harness_monitor_cache_read_duration_ms")
    )
  }

  // MARK: - Resource Metrics

  func testResourceGaugesRecordMemoryValues() {
    HarnessMonitorTelemetry.shared.recordResourceMetrics(
      residentMemoryBytes: 104_857_600, virtualMemoryBytes: 419_430_400
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let metricNames = collector.metricCollector.metricNames
    XCTAssertTrue(metricNames.contains("harness_monitor_memory_resident_bytes"))
    XCTAssertTrue(metricNames.contains("harness_monitor_memory_virtual_bytes"))
  }

  // MARK: - Error Categorization

  func testAPIErrorCounterIncrementsWithErrorType() {
    HarnessMonitorTelemetry.shared.recordAPIError(
      endpoint: "/v1/sessions", method: "GET", errorType: "timeout", statusCode: nil
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let metricNames = collector.metricCollector.metricNames
    XCTAssertTrue(metricNames.contains("harness_monitor_api_errors_total"))
    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_api_errors_total"
    )
    XCTAssertTrue(dataPoints.contains { $0.attributes["error.type"] == "timeout" })
  }

  func testDecodingErrorCounterIncrementsWithEntity() {
    HarnessMonitorTelemetry.shared.recordDecodingError(
      entity: "SessionDetail", reason: "Missing required field 'id'"
    )
    HarnessMonitorTelemetry.shared.shutdown()

    XCTAssertTrue(
      collector.metricCollector.metricNames.contains("harness_monitor_decoding_errors_total")
    )
  }

  func testTimeoutErrorCounterIncrementsWithOperation() {
    HarnessMonitorTelemetry.shared.recordTimeoutError(
      operation: "http_request", durationMs: 30000.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    XCTAssertTrue(
      collector.metricCollector.metricNames.contains("harness_monitor_timeout_errors_total")
    )
  }

  // MARK: - Semantic Resource Attributes

  func testSemanticResourceAttributesIncludeOSInfo() {
    HarnessMonitorTelemetry.shared.recordAppLifecycleEvent(
      event: "active", launchMode: "live", durationMs: nil
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let hasSpans = collector.traceCollector.hasReceivedSpans
    let hasMetrics = collector.metricCollector.hasReceivedMetrics
    XCTAssertTrue(hasSpans || hasMetrics)
    let resourceAttributes = collector.metricCollector.resourceAttributes
    XCTAssertTrue(resourceAttributes.contains { $0.key == "os.type" && $0.value == "darwin" })
    XCTAssertTrue(resourceAttributes.contains { $0.key == "os.version" })
    XCTAssertTrue(resourceAttributes.contains { $0.key == "host.arch" })
  }

  func testSemanticResourceAttributesIncludeUserAgent() {
    HarnessMonitorTelemetry.shared.recordAppLifecycleEvent(
      event: "active", launchMode: "live", durationMs: nil
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let resourceAttributes = collector.metricCollector.resourceAttributes
    XCTAssertTrue(resourceAttributes.contains { $0.key == "user_agent.original" })
  }
}

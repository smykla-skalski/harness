import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor observability Phase 1 metrics")
struct HarnessMonitorObservabilityPhase1Tests {

  // MARK: - App Lifecycle

  @Test("App lifecycle counter increments on event")
  func appLifecycleCounterIncrementsOnEvent() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordAppLifecycleEvent(
      event: "bootstrap",
      launchMode: "live",
      durationMs: 150.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_app_lifecycle_total"))
    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_app_lifecycle_total"
    )
    #expect(dataPoints.contains { $0.attributes["app.lifecycle.event"] == "bootstrap" })
  }

  @Test("App bootstrap duration records histogram")
  func appBootstrapDurationRecordsHistogram() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordAppLifecycleEvent(
      event: "bootstrap",
      launchMode: "live",
      durationMs: 250.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    #expect(collector.metricCollector.metricNames.contains("harness_monitor_bootstrap_duration_ms"))
  }

  // MARK: - User Interactions

  @Test("User interaction counter increments with attributes")
  func userInteractionCounterIncrementsWithAttributes() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordUserInteraction(
      interaction: "select_session",
      sessionID: "test-session-123",
      durationMs: 45.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_user_interactions_total"))
    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_user_interactions_total"
    )
    #expect(
      dataPoints.contains { $0.attributes["user.interaction.type"] == "select_session" }
    )
  }

  // MARK: - Cache Observability

  @Test("Cache hit counter increments on hit")
  func cacheHitCounterIncrementsOnHit() async throws {
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
      durationMs: 2.5
    )
    HarnessMonitorTelemetry.shared.shutdown()

    #expect(collector.metricCollector.metricNames.contains("harness_monitor_cache_hits_total"))
  }

  @Test("Cache miss counter increments on miss")
  func cacheMissCounterIncrementsOnMiss() async throws {
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
      durationMs: 3.2
    )
    HarnessMonitorTelemetry.shared.shutdown()

    #expect(collector.metricCollector.metricNames.contains("harness_monitor_cache_misses_total"))
  }

  @Test("Cache read duration records latency")
  func cacheReadDurationRecordsLatency() async throws {
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
      durationMs: 5.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_cache_read_duration_ms"))
  }

  // MARK: - Resource Metrics

  @Test("Resource gauges record memory values")
  func resourceGaugesRecordMemoryValues() async throws {
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
      residentMemoryBytes: 104_857_600,
      virtualMemoryBytes: 419_430_400
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_memory_resident_bytes"))
    #expect(metricNames.contains("harness_monitor_memory_virtual_bytes"))
  }

  // MARK: - Error Categorization

  @Test("API error counter increments with error type")
  func apiErrorCounterIncrementsWithErrorType() async throws {
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

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_api_errors_total"))
    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_api_errors_total"
    )
    #expect(dataPoints.contains { $0.attributes["error.type"] == "timeout" })
  }

  @Test("Decoding error counter increments with entity")
  func decodingErrorCounterIncrementsWithEntity() async throws {
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
      reason: "Missing required field 'id'"
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_decoding_errors_total"))
  }

  @Test("Timeout error counter increments with operation")
  func timeoutErrorCounterIncrementsWithOperation() async throws {
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

    #expect(collector.metricCollector.metricNames.contains("harness_monitor_timeout_errors_total"))
  }

  // MARK: - Semantic Resource Attributes

  @Test("Semantic resource attributes include OS info")
  func semanticResourceAttributesIncludeOSInfo() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordAppLifecycleEvent(
      event: "active",
      launchMode: "live",
      durationMs: nil
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let hasSpans = collector.traceCollector.hasReceivedSpans
    let hasMetrics = collector.metricCollector.hasReceivedMetrics
    #expect(hasSpans || hasMetrics)
    let resourceAttributes = collector.metricCollector.resourceAttributes
    #expect(resourceAttributes.contains { $0.key == "os.type" && $0.value == "darwin" })
    #expect(resourceAttributes.contains { $0.key == "os.version" })
    #expect(resourceAttributes.contains { $0.key == "host.arch" })
  }

  @Test("Semantic resource attributes include user agent")
  func semanticResourceAttributesIncludeUserAgent() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.recordAppLifecycleEvent(
      event: "active",
      launchMode: "live",
      durationMs: nil
    )
    HarnessMonitorTelemetry.shared.shutdown()

    let resourceAttributes = collector.metricCollector.resourceAttributes
    #expect(resourceAttributes.contains { $0.key == "user_agent.original" })
  }
}

import Foundation
import OSLog
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor observability Phase 5 signpost bridge and view profiling")
struct HarnessMonitorObservabilityPhase5Tests {

  // MARK: - Signpost Bridge Tests

  @Test("Signpost bridge creates span for interval")
  func signpostBridgeCreatesSpanForInterval() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let bridge = HarnessMonitorSignpostBridge()
    let (state, span) = bridge.beginInterval(name: "test_operation")
    bridge.endInterval(name: "test_operation", state: state)
    span.end()

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.traceCollector.hasReceivedSpans
    }

    let spans = collector.traceCollector.exportedSpans
    let hasSignpostSpan = spans.contains { $0.name == "perf.test_operation" }
    #expect(hasSignpostSpan)
  }

  @Test("Signpost bridge emits span with correct name")
  func signpostBridgeEmitsSpanWithCorrectName() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let bridge = HarnessMonitorSignpostBridge()
    let (state, span) = bridge.beginInterval(name: "dashboard_render")
    bridge.endInterval(name: "dashboard_render", state: state)
    span.end()

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.traceCollector.hasReceivedSpans
    }

    let spans = collector.traceCollector.exportedSpans
    let signpostSpan = spans.first { $0.name == "perf.dashboard_render" }
    #expect(signpostSpan != nil)
  }

  @Test("Signpost bridge ends the owned OTEL span when the interval finishes")
  func signpostBridgeEndsOwnedSpanOnIntervalEnd() {
    let bridge = HarnessMonitorSignpostBridge()
    let (state, span) = bridge.beginInterval(name: "bridge_owned_interval")
    #expect(span.isRecording)

    bridge.endInterval(name: "bridge_owned_interval", state: state)
    #expect(!span.isRecording)
  }

  // MARK: - View Signposter Tests

  @Test("View signposter measures view body")
  func viewSignposterMeasuresViewBody() {
    var bodyEvaluated = false
    _ = ViewBodySignposter.measure("TestView") {
      bodyEvaluated = true
      return 42
    }
    #expect(bodyEvaluated)
  }

  @Test("View signposter returns body result")
  func viewSignposterReturnsBodyResult() {
    let result = ViewBodySignposter.measure("TestView") {
      "hello"
    }
    #expect(result == "hello")
  }

  // MARK: - Exemplar Tests

  @Test("Histogram recording works with active span context")
  func histogramRecordingWorksWithActiveSpanContext() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let span = HarnessMonitorTelemetry.shared.startSpan(
      name: "exemplar_test",
      kind: .internal,
      attributes: [:]
    )
    HarnessMonitorTelemetry.shared.recordUserInteraction(
      interaction: "test_interaction",
      sessionID: "sess-exemplar",
      durationMs: 100.0
    )
    span.end()
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_user_interaction_duration_ms"))
  }
}

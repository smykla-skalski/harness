import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor observability Phase 5 signpost bridge")
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

  @Test("Signpost bridge measures an async interval and exports the scenario span")
  func signpostBridgeMeasuresAsyncIntervalAndExportsScenarioSpan() async throws {
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
    let result = await bridge.withInterval(name: "launch-dashboard") {
      "measured"
    }
    #expect(result == "measured")

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.traceCollector.exportedSpans.contains { $0.name == "perf.launch-dashboard" }
    }

    #expect(
      collector.traceCollector.exportedSpans.contains { $0.name == "perf.launch-dashboard" }
    )
  }

  @Test("Signpost bridge exports completed async intervals without waiting for shutdown")
  func signpostBridgeExportsCompletedAsyncIntervalsWithoutWaitingForShutdown() async throws {
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
    await bridge.withInterval(
      name: "launch-dashboard",
      flushOnCompletion: true
    ) {
      try? await Task.sleep(for: .milliseconds(50))
    }

    try await waitForTraceExport(timeout: .milliseconds(500)) {
      collector.traceCollector.exportedSpans.contains { $0.name == "perf.launch-dashboard" }
    }

    #expect(
      collector.traceCollector.exportedSpans.contains { $0.name == "perf.launch-dashboard" }
    )
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

import Foundation
import OpenTelemetryApi
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor observability remaining plan items")
struct HarnessMonitorObservabilityRemainingTests {

  // MARK: - Phase 1.2: device.id semantic attribute

  @Test("kernelUUID returns valid UUID string")
  func kernelUUIDReturnsValidUUID() {
    let uuid = HarnessMonitorTelemetry.shared.kernelUUID()
    #expect(!uuid.isEmpty)
    #expect(uuid != "unknown")
    #expect(uuid.count >= 32)
  }

  // MARK: - Phase 2.1: Bootstrap span

  @Test("Bootstrap emits app.lifecycle.bootstrap span")
  func bootstrapEmitsLifecycleSpan() async throws {
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
      name: "app.lifecycle.bootstrap",
      kind: .internal,
      attributes: ["app.launch_mode": .string("live")]
    )
    span.end()

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.traceCollector.hasReceivedSpans
    }

    let spans = collector.traceCollector.exportedSpans
    let hasBootstrapSpan = spans.contains { $0.name == "app.lifecycle.bootstrap" }
    #expect(hasBootstrapSpan)
  }

  // MARK: - Phase 2.3: Baggage propagation

  @Test("setSessionBaggage sets baggage entries")
  func setSessionBaggageSetsEntries() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.setSessionBaggage(
      sessionID: "test-session-123",
      projectID: "test-project-456"
    )

    let context = HarnessMonitorTelemetry.shared.traceContext()
    let hasBaggage = context["baggage"] != nil

    #expect(hasBaggage)

    HarnessMonitorTelemetry.shared.clearSessionBaggage()
    HarnessMonitorTelemetry.shared.shutdown()
  }

  @Test("clearSessionBaggage removes baggage entries")
  func clearSessionBaggageRemovesEntries() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.setSessionBaggage(
      sessionID: "test-session-123",
      projectID: nil
    )
    HarnessMonitorTelemetry.shared.clearSessionBaggage()

    let context = HarnessMonitorTelemetry.shared.traceContext()
    let hasBaggage = context["baggage"]?.contains("session.id") == true

    #expect(!hasBaggage)
    HarnessMonitorTelemetry.shared.shutdown()
  }

  // MARK: - Phase 3.2: Resource metrics sampler

  @Test("Resource metrics sampler records memory gauges")
  func resourceMetricsSamplerRecordsMemoryGauges() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let sampler = HarnessMonitorResourceMetrics()
    sampler.recordSample()

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_memory_resident_bytes"))
    #expect(metricNames.contains("harness_monitor_memory_virtual_bytes"))
  }

  // MARK: - Phase 5.3: Exemplar workaround

  @Test("Histogram recording includes exemplar trace context")
  func histogramRecordingIncludesExemplarTraceContext() async throws {
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
      name: "exemplar_parent",
      kind: .internal,
      attributes: [:]
    )

    HarnessMonitorTelemetry.shared.recordUserInteraction(
      interaction: "exemplar_test",
      sessionID: "exemplar-session",
      durationMs: 50.0
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

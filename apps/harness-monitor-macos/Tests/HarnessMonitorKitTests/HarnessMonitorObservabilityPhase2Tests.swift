import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor observability Phase 2 lifecycle and interaction spans")
struct HarnessMonitorObservabilityPhase2Tests {

  // MARK: - App Lifecycle Spans

  @Test("Application resign active records lifecycle event")
  func applicationResignActiveRecordsLifecycleEvent() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.withAppLifecycleTransition(
      event: "resign_active",
      launchMode: "live"
    ) {}
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics && collector.traceCollector.hasReceivedSpans
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_app_lifecycle_total"))

    let attributes = try #require(
      lifecycleSpanAttributes(
        in: collector.traceCollector,
        spanName: "app.lifecycle.resign_active"
      )
    )
    #expect(attributes["app.launch_mode"] == "live")
  }

  @Test("Application become active records lifecycle event")
  func applicationBecomeActiveRecordsLifecycleEvent() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    HarnessMonitorTelemetry.shared.withAppLifecycleTransition(
      event: "become_active",
      launchMode: "live"
    ) {}
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics && collector.traceCollector.hasReceivedSpans
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_app_lifecycle_total"))

    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_app_lifecycle_total"
    )
    let hasActiveEvent = dataPoints.contains { dp in
      dp.attributes["app.lifecycle.event"] == "become_active"
    }
    #expect(hasActiveEvent)

    let attributes = try #require(
      lifecycleSpanAttributes(
        in: collector.traceCollector,
        spanName: "app.lifecycle.active"
      )
    )
    #expect(attributes["app.launch_mode"] == "live")
  }

  @Test("Bootstrap records lifecycle event with duration")
  func bootstrapRecordsLifecycleEventWithDuration() async throws {
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

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_app_lifecycle_total"))
    #expect(metricNames.contains("harness_monitor_bootstrap_duration_ms"))
  }

  // MARK: - User Interaction Spans

  @Test("User interaction records counter and duration")
  func userInteractionRecordsCounterAndDuration() async throws {
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
      sessionID: "sess-123",
      durationMs: 45.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_user_interactions_total"))
    #expect(metricNames.contains("harness_monitor_user_interaction_duration_ms"))

    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_user_interactions_total"
    )
    let hasSelectSession = dataPoints.contains { dp in
      dp.attributes["user.interaction.type"] == "select_session"
    }
    #expect(hasSelectSession)
  }

  @Test("User interaction without session ID records nil session attribute")
  func userInteractionWithoutSessionIDRecordsNilSessionAttribute() async throws {
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
      interaction: "deselect_session",
      sessionID: nil,
      durationMs: 10.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_user_interactions_total"))
  }

  @Test("Mutate session action records user interaction")
  func mutateSessionActionRecordsUserInteraction() async throws {
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
      interaction: "create_task",
      sessionID: "sess-456",
      durationMs: 200.0
    )
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    let dataPoints = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_user_interactions_total"
    )
    let hasCreateTask = dataPoints.contains { dp in
      dp.attributes["user.interaction.type"] == "create_task"
    }
    #expect(hasCreateTask)
  }

  // MARK: - Span Tests

  @Test("User action span is emitted for session mutation")
  func userActionSpanEmittedForSessionMutation() async throws {
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
      name: "user.action.create_task",
      kind: .internal,
      attributes: [
        "user.action.name": .string("Create task"),
        "session.id": .string("sess-789"),
      ]
    )
    span.end()
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.traceCollector.hasReceivedSpans
    }

    let spans = collector.traceCollector.exportedSpans
    let hasActionSpan = spans.contains {
      $0.name == "user.action.create_task"
    }
    #expect(hasActionSpan)
  }

  @Test("Session selection span is emitted")
  func sessionSelectionSpanEmitted() async throws {
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
      name: "user.interaction.select_session",
      kind: .internal,
      attributes: ["session.id": .string("sess-select")]
    )
    span.end()
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.traceCollector.hasReceivedSpans
    }

    let spans = collector.traceCollector.exportedSpans
    let hasSelectionSpan = spans.contains {
      $0.name == "user.interaction.select_session"
    }
    #expect(hasSelectionSpan)
  }
}

private func lifecycleSpanAttributes(
  in collector: FakeTraceCollector,
  spanName: String
) -> [String: String]? {
  for span in collector.receivedSpans.flatMap(\.scopeSpans).flatMap(\.spans) {
    guard span.name == spanName else {
      continue
    }
    return Dictionary(
      uniqueKeysWithValues: span.attributes.map { attribute in
        (attribute.key, attribute.value.stringValue)
      }
    )
  }
  return nil
}

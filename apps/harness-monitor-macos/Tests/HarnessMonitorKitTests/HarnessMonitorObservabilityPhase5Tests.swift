import AppKit
import Foundation
import OSLog
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

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

  @Test("View signposter exports a view span with the measured view name")
  func viewSignposterExportsViewSpanWithMeasuredViewName() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    _ = ViewBodySignposter.measure("SessionCockpitView") {
      "profiled"
    }

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "SessionCockpitView"
      ) != nil
    }

    let attributes = try #require(
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "SessionCockpitView"
      )
    )
    #expect(attributes["perf.signpost.name"] == "view.body")
    #expect(attributes["harness.view.name"] == "SessionCockpitView")
  }

  @MainActor
  @Test("Critical cockpit views emit profiled body spans when rendered")
  func criticalCockpitViewsEmitProfiledBodySpansWhenRendered() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)
    let cockpitView = SessionCockpitView(
      store: store,
      detail: PreviewFixtures.detail,
      timeline: PreviewFixtures.timeline,
      timelineWindow: .fallbackMetadata(for: PreviewFixtures.timeline),
      isSessionStatusStale: false,
      isSessionReadOnly: false,
      isTimelineLoading: false,
      isExtensionsLoading: false
    )
    let timelineSection = SessionCockpitTimelineSection(
      sessionID: PreviewFixtures.summary.sessionId,
      timeline: PreviewFixtures.timeline,
      timelineWindow: .fallbackMetadata(for: PreviewFixtures.timeline),
      isTimelineLoading: false,
      loadPage: { _, _ in }
    )

    render(cockpitView, width: 1_440, height: 1_024)
    render(timelineSection, width: 960, height: 720)

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "SessionCockpitView"
      ) != nil
        && viewBodySpanAttributes(
          in: collector.traceCollector,
          viewName: "SessionCockpitTimelineSection"
        ) != nil
    }

    #expect(
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "SessionCockpitView"
      ) != nil
    )
    #expect(
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "SessionCockpitTimelineSection"
      ) != nil
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

private func viewBodySpanAttributes(
  in collector: FakeTraceCollector,
  viewName: String
) -> [String: String]? {
  for span in collector.receivedSpans.flatMap(\.scopeSpans).flatMap(\.spans) {
    let attributes = Dictionary(
      uniqueKeysWithValues: span.attributes.map { attribute in
        (attribute.key, attribute.value.stringValue)
      }
    )
    guard span.name == "perf.view.body",
      attributes["harness.view.name"] == viewName
    else {
      continue
    }
    return attributes
  }
  return nil
}

@MainActor
private func render<Content: View>(
  _ view: Content,
  width: CGFloat,
  height: CGFloat
) {
  let host = NSHostingView(rootView: view)
  host.frame = CGRect(x: 0, y: 0, width: width, height: height)
  host.layoutSubtreeIfNeeded()
  _ = host.fittingSize
}

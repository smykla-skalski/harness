import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor observability phase 3 activity metrics")
struct HarnessMonitorObservabilityPhase3ActivityTests {

  @Test("Session snapshot records active task gauge")
  func sessionSnapshotRecordsActiveTaskGauge() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.applySessionIndexSnapshot(
      projects: PreviewFixtures.projects,
      sessions: [PreviewFixtures.summary]
    )

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    #expect(collector.metricCollector.metricNames.contains("harness_monitor_active_tasks"))
  }

  @Test("WebSocket online state records connection gauge")
  func webSocketOnlineStateRecordsConnectionGauge() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.activeTransport = .webSocket
    store.connectionState = .online

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics
    }

    #expect(
      collector.metricCollector.metricNames.contains("harness_monitor_websocket_connections")
    )
  }
}

import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store observability lifecycle")
struct HarnessMonitorStoreObservabilityLifecycleTests {

  @Test("Bootstrap starts and termination stops resource metric sampling")
  func bootstrapStartsAndTerminationStopsResourceMetricSampling() async {
    let sampler = ResourceMetricsSamplerSpy()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: RecordingHarnessClient())
    )
    store.resourceMetricsSampler = sampler

    await store.bootstrap()
    #expect(sampler.startCallCount() == 1)

    await store.prepareForTermination()
    #expect(sampler.stopCallCount() == 1)
  }

  @Test("Managed bootstrap records phase telemetry for launch agent warm-up and connect")
  func managedBootstrapRecordsPhaseTelemetry() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: RecordingHarnessClient())
    )

    await store.bootstrap()
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      collector.metricCollector.hasReceivedMetrics && collector.traceCollector.hasReceivedSpans
    }

    let points = collector.metricCollector.dataPointsForMetric(
      "harness_monitor_bootstrap_phase_duration_ms"
    )
    #expect(
      points.contains { dataPoint in
        dataPoint.attributes["bootstrap.phase"] == "managed_launch_agent_ready"
      }
    )
    #expect(
      points.contains { dataPoint in
        dataPoint.attributes["bootstrap.phase"] == "managed_daemon_warm_up"
      }
    )
    #expect(
      points.contains { dataPoint in
        dataPoint.attributes["bootstrap.phase"] == "managed_initial_connect"
      }
    )

    let spans = collector.traceCollector.exportedSpans
    #expect(spans.contains { $0.name == "app.lifecycle.bootstrap.managed_launch_agent_ready" })
    #expect(spans.contains { $0.name == "app.lifecycle.bootstrap.managed_daemon_warm_up" })
    #expect(spans.contains { $0.name == "app.lifecycle.bootstrap.managed_initial_connect" })
  }
}

private final class ResourceMetricsSamplerSpy: HarnessMonitorResourceSampling, @unchecked Sendable {
  private let lock = NSLock()
  private var startCalls = 0
  private var stopCalls = 0

  func startSampling() {
    lock.withLock {
      startCalls += 1
    }
  }

  func stopSampling() {
    lock.withLock {
      stopCalls += 1
    }
  }

  func startCallCount() -> Int {
    lock.withLock { startCalls }
  }

  func stopCallCount() -> Int {
    lock.withLock { stopCalls }
  }
}

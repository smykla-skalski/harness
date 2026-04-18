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

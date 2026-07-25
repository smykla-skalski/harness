import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Daemon wire version skew")
struct DaemonWireVersionSkewTests {
  private func store(reportingWireVersion wireVersion: Int) -> HarnessMonitorStore {
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: RecordingHarnessClient())
    )
    store.health = HealthResponse(
      status: "ok",
      version: "51.0.0",
      pid: 1,
      endpoint: "http://127.0.0.1:1",
      startedAt: "2026-07-25T10:00:00Z",
      projectCount: 1,
      sessionCount: 1,
      wireVersion: wireVersion
    )
    return store
  }

  @Test("A daemon one version behind the minimum is skewed")
  func aDaemonOneVersionBehindTheMinimumIsSkewed() {
    let behind = store(
      reportingWireVersion: HarnessMonitorStore.minimumDaemonWireVersion - 1
    )

    #expect(behind.isDaemonWireVersionSkewed)
  }

  @Test("A daemon at the minimum is not skewed")
  func aDaemonAtTheMinimumIsNotSkewed() {
    let current = store(reportingWireVersion: HarnessMonitorStore.minimumDaemonWireVersion)

    #expect(!current.isDaemonWireVersionSkewed)
  }

  /// The projects catalog decodes `color` and `shape` as required, so a daemon
  /// that predates them cannot serve it. Wire 2 is the last version that did,
  /// which is why the gate had to move off it rather than keep accepting them:
  /// the skew banner names the problem, where the alternative was the catalog
  /// failing to decode and surfacing a raw decoding error in a toast.
  @Test("A daemon predating the project mark no longer connects clean")
  func aDaemonPredatingTheProjectMarkNoLongerConnectsClean() {
    let preMark = store(reportingWireVersion: 2)

    #expect(preMark.isDaemonWireVersionSkewed)
  }
}

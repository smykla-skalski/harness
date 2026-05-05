import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor external daemon recovery toasts")
struct ExternalDaemonRecoveryToastTests {
  @Test("External offline recovery toast keeps command and path in details")
  func externalOfflineRecoveryToastKeepsDiagnosticsInDetails() async throws {
    let manifestPath = "/tmp/harness/daemon/manifest.json"
    let daemon = RecordingDaemonController(
      warmUpError: DaemonControlError.externalDaemonOffline(manifestPath: manifestPath)
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )

    await store.bootstrap()

    let feedback = try #require(store.toast.activeFeedback.first)
    #expect(feedback.title == "Start background helper")
    #expect(feedback.severity == .warning)
    #expect(feedback.details?.disclosureLabel == "restart details")
    #expect(feedback.details?.command?.contains("harness daemon dev") == true)
    #expect(feedback.details?.rows.contains { $0.value == manifestPath } == true)
    #expect(feedback.primaryAction?.title == "Copy Terminal restart command")
  }

  @Test("Stale manifest recovery toast explains restart safety")
  func staleManifestRecoveryToastExplainsRestartSafety() async throws {
    let manifestPath = "/tmp/stale/manifest.json"
    let daemon = RecordingDaemonController(
      warmUpError: DaemonControlError.externalDaemonManifestStale(
        manifestPath: manifestPath
      )
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )

    await store.bootstrap()

    let feedback = try #require(store.toast.activeFeedback.first)
    #expect(feedback.title == "Restart background helper")
    #expect(feedback.message.contains("restart the helper in Terminal"))
    #expect(feedback.details?.summary?.contains("does not delete profile data") == true)
    #expect(feedback.details?.command?.contains("harness daemon dev") == true)
    #expect(feedback.details?.rows.contains { $0.value == manifestPath } == true)
    #expect(feedback.primaryAction?.successAnnouncement == "Terminal restart command copied")
  }
}

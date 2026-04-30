import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Database file viewer handoff")
struct HarnessMonitorStoreFileViewerTests {
  @Test("Reveal in Finder targets the harness data root")
  func revealInFinderTargetsHarnessDataRoot() {
    let fileViewer = RecordingFileViewer()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      fileViewer: fileViewer
    )

    store.revealDatabaseInFinder()

    #expect(fileViewer.revealedBatches.count == 1)
    #expect(fileViewer.revealedBatches[0] == [HarnessMonitorPaths.harnessRoot()])
  }

  @Test("Open daemon log reveals the daemon events log")
  func openDaemonLogRevealsDaemonEventsLog() {
    let fileViewer = RecordingFileViewer()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      fileViewer: fileViewer
    )
    store.daemonStatus = sandboxedStatus(hostBridge: HostBridgeManifest())

    let opened = store.revealDaemonLogInFinder()

    #expect(opened)
    #expect(fileViewer.revealedBatches.count == 1)
    #expect(fileViewer.revealedBatches[0] == [URL(fileURLWithPath: "/tmp/harness/daemon/events.jsonl")])
  }

  @Test("Open daemon log reports when diagnostics do not expose a log path")
  func openDaemonLogReportsUnavailablePath() {
    let fileViewer = RecordingFileViewer()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      fileViewer: fileViewer
    )

    let opened = store.revealDaemonLogInFinder()

    #expect(opened == false)
    #expect(fileViewer.revealedBatches.isEmpty)
    #expect(store.currentFailureFeedbackMessage == "Daemon log is unavailable.")
  }

  @Test("Reveal ACP permission log opens the file in Finder")
  func revealAcpPermissionLogRevealsPath() {
    let fileViewer = RecordingFileViewer()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      fileViewer: fileViewer
    )

    let result = store.revealAcpPermissionLogInFinder(
      runID: "run-a",
      rawPath: "/tmp/harness/permission-log.ndjson"
    )

    #expect(result == .revealed)
    #expect(fileViewer.revealedBatches.count == 1)
    #expect(fileViewer.revealedBatches[0] == [URL(fileURLWithPath: "/tmp/harness/permission-log.ndjson")])
  }

  @Test("Reveal ACP permission log reports missing path")
  func revealAcpPermissionLogReportsUnavailablePath() {
    let fileViewer = RecordingFileViewer()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      fileViewer: fileViewer
    )

    let result = store.revealAcpPermissionLogInFinder(
      runID: "run-a",
      rawPath: ""
    )

    #expect(result == .unavailable)
    #expect(fileViewer.revealedBatches.isEmpty)
    #expect(store.currentFailureFeedbackMessage == "ACP permission log for run-a is unavailable.")
  }
}

@MainActor
private final class RecordingFileViewer: FileViewerActivating {
  private(set) var revealedBatches: [[URL]] = []

  func reveal(itemsAt urls: [URL]) {
    revealedBatches.append(urls)
  }
}

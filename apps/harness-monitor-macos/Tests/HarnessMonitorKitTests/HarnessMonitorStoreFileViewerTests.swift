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
}

@MainActor
private final class RecordingFileViewer: FileViewerActivating {
  private(set) var revealedBatches: [[URL]] = []

  func reveal(itemsAt urls: [URL]) {
    revealedBatches.append(urls)
  }
}

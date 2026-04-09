import SwiftData

@testable import HarnessMonitorKit

@MainActor
struct SessionCacheMemoryTestHarness {
  let container: ModelContainer

  init() throws {
    container = try HarnessMonitorModelContainer.preview()
  }

  func makeStore() -> HarnessMonitorStore {
    HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
  }
}

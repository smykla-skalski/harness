#if DEBUG
  import Foundation
  import HarnessMonitorKit

  extension HarnessMonitorAppConfiguration {
    /// Synthesizes a fixed ``BookmarkStore/Record`` into the store when the
    /// `HARNESS_MONITOR_PRESEED_BOOKMARK=1` environment variable is set.
    ///
    /// Only active in DEBUG builds. Intended exclusively for UI-test preseed
    /// scenarios where driving the real `.fileImporter` flow is not feasible.
    @MainActor
    static func seedPreseedBookmark(
      environment: HarnessMonitorEnvironment,
      store: HarnessMonitorStore
    ) {
      guard
        environment.values["HARNESS_MONITOR_PRESEED_BOOKMARK"]?
          .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
      else {
        return
      }
      guard let bookmarkStore = store.bookmarkStore else {
        return
      }
      let record = BookmarkStore.Record(
        id: "B-preseed",
        kind: .projectRoot,
        displayName: "preseed",
        lastResolvedPath: FileManager.default.temporaryDirectory.path,
        bookmarkData: Data(),
        createdAt: .now,
        lastAccessedAt: .now,
        staleCount: 0
      )
      Task {
        try? await bookmarkStore.insertForTesting(record)
      }
    }
  }
#endif

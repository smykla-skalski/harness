#if DEBUG
  import Foundation
  import HarnessMonitorKit

  extension HarnessMonitorAppConfiguration {
    private static let preseedEnvKey = "HARNESS_MONITOR_PRESEED_BOOKMARK"

    /// Synthesizes a fixed ``BookmarkStore/Record`` into the store when the
    /// `HARNESS_MONITOR_PRESEED_BOOKMARK=1` environment variable is set.
    ///
    /// Only active in DEBUG builds and only when the app is also launched in
    /// UI-testing mode (`isUITesting == true`). The insert is async on the
    /// bookmark actor; the UI test's `waitForExistence` polling covers the
    /// narrow window where the Authorized Folders section reads an empty
    /// snapshot before the insert lands. Errors are logged instead of
    /// silently dropped so a broken preseed surfaces in test logs.
    @MainActor
    static func seedPreseedBookmark(
      environment: HarnessMonitorEnvironment,
      store: HarnessMonitorStore
    ) {
      guard
        environment.values[preseedEnvKey]?
          .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
      else {
        return
      }
      guard let bookmarkStore = store.bookmarkStore else {
        HarnessMonitorLogger.store.warning(
          "preseed requested but bookmark store is unavailable"
        )
        return
      }
      let record = BookmarkStore.Record(
        id: "B-preseed",
        kind: .projectRoot,
        displayName: "harness",
        lastResolvedPath: FileManager.default.temporaryDirectory
          .appendingPathComponent("harness", isDirectory: true)
          .path,
        bookmarkData: Data(),
        createdAt: .now,
        lastAccessedAt: .now,
        staleCount: 0
      )
      Task {
        do {
          try await bookmarkStore.insertForTesting(record)
        } catch {
          HarnessMonitorLogger.store.error(
            "preseed insert failed: \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
  }
#endif

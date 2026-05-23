import AppKit
import Foundation
import SwiftData

public protocol FileViewerActivating {
  @MainActor
  func reveal(itemsAt urls: [URL])

  @MainActor
  func open(itemAt url: URL)
}

extension FileViewerActivating {
  @MainActor
  public func open(itemAt url: URL) {
    reveal(itemsAt: [url])
  }
}

public struct WorkspaceFileViewer: FileViewerActivating {
  public init() {}

  @MainActor
  public func reveal(itemsAt urls: [URL]) {
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  @MainActor
  public func open(itemAt url: URL) {
    _ = NSWorkspace.shared.open(url)
  }
}

public enum RevealAcpPermissionLogResult: Equatable {
  case revealed
  case unavailable
}

public struct DatabaseStatistics: Sendable {
  public let sessionCount: Int
  public let projectCount: Int
  public let agentCount: Int
  public let taskCount: Int
  public let signalCount: Int
  public let timelineCount: Int
  public let transcriptCount: Int
  public let observerCount: Int
  public let activityCount: Int
  public let bookmarkCount: Int
  public let noteCount: Int
  public let searchCount: Int
  public let filterPreferenceCount: Int
  public let notificationCount: Int
  public let appCacheSizeBytes: Int64
  public let daemonDatabaseSizeBytes: Int
  public let lastCachedAt: Date?
  public let appCacheStorePath: String
  public let daemonDatabasePath: String

  @MainActor private static let byteCountFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
  }()

  @MainActor private static let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  @MainActor
  public static func formatByteCount(_ byteCount: Int64) -> String {
    byteCountFormatter.string(fromByteCount: byteCount)
  }

  @MainActor public var appCacheSizeFormatted: String {
    Self.formatByteCount(appCacheSizeBytes)
  }

  @MainActor public var daemonDatabaseSizeFormatted: String {
    Self.formatByteCount(Int64(daemonDatabaseSizeBytes))
  }

  @MainActor public var lastCachedFormatted: String {
    guard let lastCachedAt else { return "Never" }
    return Self.relativeDateFormatter.localizedString(for: lastCachedAt, relativeTo: .now)
  }

  public var totalCacheRecords: Int {
    sessionCount + projectCount + agentCount + taskCount
      + signalCount + timelineCount + transcriptCount + observerCount + activityCount
  }

  public var totalUserRecords: Int {
    bookmarkCount + noteCount + searchCount + filterPreferenceCount + notificationCount
  }
}

extension HarnessMonitorStore {
  public func gatherDatabaseStatistics() async -> DatabaseStatistics {
    let userRecordCounts: UserDataPersistenceService.RecordCounts
    if let userDataService, persistenceError == nil {
      userRecordCounts = await userDataService.recordCounts()
    } else {
      userRecordCounts = .zero
    }

    let cacheCounts: SessionCacheService.CacheCounts
    if let cacheService, persistenceError == nil {
      cacheCounts = await cacheService.recordCounts()
    } else {
      cacheCounts = .zero
    }

    let storeURL = HarnessMonitorPaths.harnessRootWithoutLiveDiscovery()
      .appendingPathComponent("harness-cache.store")
    let appCacheSizeBytes = await Self.swiftDataStoreSizeAsync(at: storeURL)

    let daemonDiagnostics = diagnostics?.workspace ?? daemonStatus?.diagnostics
    let daemonDatabaseSizeBytes = daemonDiagnostics?.databaseSizeBytes ?? 0
    let daemonDatabasePath = daemonDiagnostics?.databasePath ?? "Unavailable"

    return DatabaseStatistics(
      sessionCount: cacheCounts.sessions,
      projectCount: cacheCounts.projects,
      agentCount: cacheCounts.agents,
      taskCount: cacheCounts.tasks,
      signalCount: cacheCounts.signals,
      timelineCount: cacheCounts.timeline,
      transcriptCount: cacheCounts.transcript,
      observerCount: cacheCounts.observers,
      activityCount: cacheCounts.activities,
      bookmarkCount: userRecordCounts.bookmarks,
      noteCount: userRecordCounts.notes,
      searchCount: userRecordCounts.searches,
      filterPreferenceCount: userRecordCounts.filterPreferences,
      notificationCount: userRecordCounts.notifications,
      appCacheSizeBytes: appCacheSizeBytes,
      daemonDatabaseSizeBytes: daemonDatabaseSizeBytes,
      lastCachedAt: lastPersistedSnapshotAt,
      appCacheStorePath: storeURL.path,
      daemonDatabasePath: daemonDatabasePath
    )
  }

  @discardableResult
  public func clearSessionCache() async -> Bool {
    guard let cacheService, persistenceError == nil else {
      presentFailureFeedback(
        persistenceFailureMessage(
          action: "Session cache could not be cleared",
          underlyingError: nil
        )
      )
      return false
    }

    let success = await cacheService.deleteAllCacheData()
    if success {
      await reviewFilePreviewStore.clear()
      persistedSessionCount = 0
      lastPersistedSnapshotAt = nil
      presentSuccessFeedback("Session cache cleared")
    } else {
      presentFailureFeedback("Failed to clear session cache")
    }
    return success
  }

  @discardableResult
  public func clearAllUserData() async -> Bool {
    guard
      let userDataService = unavailablePersistenceService(
        for: "User data could not be cleared"
      )
    else {
      return false
    }

    do {
      try await userDataService.clearAllUserData()
      bookmarkedSessionIds = []
      notificationHistoryEntries = []
      notificationHistoryRuntimeActions.removeAll()
      withNotificationHistoryToastSuppressed {
        presentSuccessFeedback("User data cleared")
      }
      return true
    } catch {
      recordPersistenceFailure(
        action: "User data could not be cleared",
        underlyingError: error
      )
      return false
    }
  }

  @discardableResult
  public func clearAllDatabaseData() async -> Bool {
    let wasSuppressingNotificationHistoryToast = isSuppressingNotificationHistoryToast
    isSuppressingNotificationHistoryToast = true
    defer {
      isSuppressingNotificationHistoryToast = wasSuppressingNotificationHistoryToast
    }

    let cacheCleared = await clearSessionCache()
    let userDataCleared = await clearAllUserData()
    if cacheCleared && userDataCleared {
      presentSuccessFeedback("All database data cleared")
    }
    return cacheCleared && userDataCleared
  }

  public func revealDatabaseInFinder() {
    let url = HarnessMonitorPaths.harnessRoot()
    fileViewer.reveal(itemsAt: [url])
  }

  @discardableResult
  public func openDaemonLog() -> Bool {
    guard let url = daemonLogURL() else {
      presentFailureFeedback("Daemon log is unavailable")
      return false
    }
    fileViewer.open(itemAt: url)
    return true
  }

  @discardableResult
  public func revealAcpPermissionLogInFinder(
    runID: String,
    rawPath: String?
  ) -> RevealAcpPermissionLogResult {
    guard let url = acpPermissionLogURL(rawPath: rawPath) else {
      presentFailureFeedback("ACP permission log for \(runID) is unavailable")
      return .unavailable
    }
    fileViewer.reveal(itemsAt: [url])
    return .revealed
  }

  // MARK: - Private helpers

  func daemonLogURL() -> URL? {
    let rawPath =
      daemonStatus?.diagnostics.eventsPath ?? diagnostics?.workspace.eventsPath ?? ""
    let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPath.isEmpty else {
      return nil
    }
    return URL(fileURLWithPath: trimmedPath)
  }

  private func acpPermissionLogURL(rawPath: String?) -> URL? {
    guard let rawPath else {
      return nil
    }
    guard !rawPath.isEmpty else {
      return nil
    }
    return URL(fileURLWithPath: rawPath)
  }

  nonisolated static func swiftDataStoreSize(at url: URL) -> Int64 {
    let paths = [
      url.path,
      url.path + "-wal",
      url.path + "-shm",
    ]
    var total: Int64 = 0
    for path in paths {
      let attrs = try? FileManager.default.attributesOfItem(atPath: path)
      if let size = attrs?[.size] as? Int64 {
        total += size
      }
    }
    return total
  }

  nonisolated static func swiftDataStoreSizeAsync(at url: URL) async -> Int64 {
    await Task.detached(priority: .utility) {
      swiftDataStoreSize(at: url)
    }.value
  }
}

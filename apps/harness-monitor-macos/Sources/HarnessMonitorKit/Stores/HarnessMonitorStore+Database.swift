import AppKit
import Foundation
import SwiftData

public protocol FileViewerActivating {
  @MainActor
  func reveal(itemsAt urls: [URL])
}

public struct WorkspaceFileViewer: FileViewerActivating {
  public init() {}

  @MainActor
  public func reveal(itemsAt urls: [URL]) {
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }
}

public struct DatabaseStatistics: Sendable {
  public let sessionCount: Int
  public let projectCount: Int
  public let agentCount: Int
  public let taskCount: Int
  public let signalCount: Int
  public let timelineCount: Int
  public let observerCount: Int
  public let activityCount: Int
  public let bookmarkCount: Int
  public let noteCount: Int
  public let searchCount: Int
  public let filterPreferenceCount: Int
  public let appCacheSizeBytes: Int64
  public let daemonDatabaseSizeBytes: Int
  public let lastCachedAt: Date?
  public let appCacheStorePath: String
  public let daemonDatabasePath: String

  public var appCacheSizeFormatted: String {
    ByteCountFormatter.string(fromByteCount: appCacheSizeBytes, countStyle: .file)
  }

  public var daemonDatabaseSizeFormatted: String {
    ByteCountFormatter.string(fromByteCount: Int64(daemonDatabaseSizeBytes), countStyle: .file)
  }

  @MainActor private static let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  @MainActor public var lastCachedFormatted: String {
    guard let lastCachedAt else { return "Never" }
    return Self.relativeDateFormatter.localizedString(for: lastCachedAt, relativeTo: .now)
  }

  public var totalCacheRecords: Int {
    sessionCount + projectCount + agentCount + taskCount
      + signalCount + timelineCount + observerCount + activityCount
  }

  public var totalUserRecords: Int {
    bookmarkCount + noteCount + searchCount + filterPreferenceCount
  }
}

extension HarnessMonitorStore {
  public func gatherDatabaseStatistics() async -> DatabaseStatistics {
    let bookmarkCount = countModel(SessionBookmark.self)
    let noteCount = countModel(UserNote.self)
    let searchCount = countModel(RecentSearch.self)
    let filterPreferenceCount = countModel(ProjectFilterPreference.self)

    let cacheCounts: SessionCacheService.CacheCounts
    if let cacheService, persistenceError == nil {
      cacheCounts = await cacheService.recordCounts()
    } else {
      cacheCounts = .zero
    }

    let storeURL = HarnessMonitorPaths.harnessRoot()
      .appendingPathComponent("harness-cache.store")
    let appCacheSizeBytes = Self.swiftDataStoreSize(at: storeURL)

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
      observerCount: cacheCounts.observers,
      activityCount: cacheCounts.activities,
      bookmarkCount: bookmarkCount,
      noteCount: noteCount,
      searchCount: searchCount,
      filterPreferenceCount: filterPreferenceCount,
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
      lastError = persistenceFailureMessage(
        action: "Session cache could not be cleared.",
        underlyingError: nil
      )
      return false
    }

    let success = await cacheService.deleteAllCacheData()
    if success {
      persistedSessionCount = 0
      lastPersistedSnapshotAt = nil
      showLastAction("Session cache cleared")
    } else {
      lastError = "Failed to clear session cache."
    }
    return success
  }

  @discardableResult
  public func clearAllUserData() -> Bool {
    guard
      let modelContext = unavailablePersistenceContext(
        for: "User data could not be cleared."
      )
    else {
      return false
    }

    do {
      try deleteAllRecords(SessionBookmark.self, in: modelContext)
      try deleteAllRecords(UserNote.self, in: modelContext)
      try deleteAllRecords(RecentSearch.self, in: modelContext)
      try deleteAllRecords(ProjectFilterPreference.self, in: modelContext)
      try modelContext.save()
      bookmarkedSessionIds = []
      showLastAction("User data cleared")
      return true
    } catch {
      modelContext.rollback()
      recordPersistenceFailure(
        action: "User data could not be cleared.",
        underlyingError: error
      )
      return false
    }
  }

  @discardableResult
  public func clearAllDatabaseData() async -> Bool {
    let cacheCleared = await clearSessionCache()
    let userDataCleared = clearAllUserData()
    if cacheCleared && userDataCleared {
      showLastAction("All database data cleared")
    }
    return cacheCleared && userDataCleared
  }

  public func revealDatabaseInFinder() {
    let url = HarnessMonitorPaths.harnessRoot()
    fileViewer.reveal(itemsAt: [url])
  }

  // MARK: - Private helpers

  private func countModel<T: PersistentModel>(_ type: T.Type) -> Int {
    guard let modelContext, persistenceError == nil else { return 0 }
    return (try? modelContext.fetchCount(FetchDescriptor<T>())) ?? 0
  }

  private func deleteAllRecords<T: PersistentModel>(
    _ type: T.Type,
    in context: ModelContext
  ) throws {
    let items = try context.fetch(FetchDescriptor<T>())
    for item in items {
      context.delete(item)
    }
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
}

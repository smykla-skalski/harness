import Foundation
import SwiftData

/// Wrapper around the V21 dependency-files per-PR row set. The cache is
/// keyed by `pullRequestID` for the summary and by the compound
/// `pullRequestID + headRefOid + path` key for the file and viewed-state
/// rows; a force-push that flips the head OID writes a fresh row set
/// instead of mutating the old one in place.
public struct ReviewFilesCache {
  private let context: ModelContext

  public init(context: ModelContext) {
    self.context = context
  }

  // MARK: - Loads

  public func loadSummary(pullRequestID: String) -> CachedReviewFilesSummary? {
    guard !pullRequestID.isEmpty else { return nil }
    let descriptor = FetchDescriptor<CachedReviewFilesSummary>(
      predicate: #Predicate { $0.pullRequestID == pullRequestID }
    )
    return try? context.fetch(descriptor).first
  }

  public func loadFiles(
    pullRequestID: String,
    headRefOid: String
  ) -> [CachedReviewFile] {
    guard !pullRequestID.isEmpty, !headRefOid.isEmpty else { return [] }
    var descriptor = FetchDescriptor<CachedReviewFile>(
      predicate: #Predicate {
        $0.pullRequestID == pullRequestID && $0.headRefOid == headRefOid
      },
      sortBy: [SortDescriptor(\.sortIndex)]
    )
    descriptor.fetchLimit = 4_000
    return (try? context.fetch(descriptor)) ?? []
  }

  public func loadViewedStates(
    pullRequestID: String,
    headRefOid: String
  ) -> [String: CachedReviewFileViewedState] {
    guard !pullRequestID.isEmpty, !headRefOid.isEmpty else { return [:] }
    let descriptor = FetchDescriptor<CachedReviewFileViewedState>(
      predicate: #Predicate {
        $0.pullRequestID == pullRequestID && $0.headRefOid == headRefOid
      }
    )
    guard let rows = try? context.fetch(descriptor) else { return [:] }
    var result: [String: CachedReviewFileViewedState] = [:]
    for row in rows {
      result[row.path] = row
    }
    return result
  }

  public func countCachedFiles() -> Int {
    (try? context.fetchCount(FetchDescriptor<CachedReviewFile>())) ?? 0
  }

  // MARK: - Writes

  public func record(response: ReviewsFilesListResponse) {
    let pullRequestID = response.pullRequestID
    let headRefOid = response.headRefOid
    guard !pullRequestID.isEmpty, !headRefOid.isEmpty else { return }
    let fetchedAt = Self.parseFetchedAt(response.fetchedAt) ?? .now
    do {
      try upsertSummary(response: response, fetchedAt: fetchedAt)
      try replaceFiles(
        pullRequestID: pullRequestID,
        headRefOid: headRefOid,
        files: response.files
      )
      try replaceViewedStates(
        pullRequestID: pullRequestID,
        headRefOid: headRefOid,
        files: response.files,
        updatedAt: fetchedAt
      )
      try context.save()
    } catch {
      logCacheFailure(
        op: "record_response",
        pullRequestID: pullRequestID,
        headRefOid: headRefOid,
        error: error
      )
    }
  }

  static func parseFetchedAt(_ string: String) -> Date? {
    if let date = try? Date(string, strategy: .iso8601) { return date }
    return try? Date(
      string,
      strategy: .iso8601.year().month().day()
        .dateSeparator(.dash)
        .time(includingFractionalSeconds: true)
        .timeZone(separator: .colon)
    )
  }

  public func updateViewedState(
    pullRequestID: String,
    headRefOid: String,
    path: String,
    viewedState: ReviewFileViewedState,
    updatedAt: Date = .now
  ) {
    guard !pullRequestID.isEmpty, !headRefOid.isEmpty, !path.isEmpty else { return }
    let key = CachedReviewFileViewedState.makeCompoundKey(
      pullRequestID: pullRequestID,
      headRefOid: headRefOid,
      path: path
    )
    do {
      let descriptor = FetchDescriptor<CachedReviewFileViewedState>(
        predicate: #Predicate { $0.compoundKey == key }
      )
      if let existing = try context.fetch(descriptor).first {
        existing.viewedStateRaw = viewedState.rawValue
        existing.updatedAt = updatedAt
      } else {
        let row = CachedReviewFileViewedState(
          pullRequestID: pullRequestID,
          headRefOid: headRefOid,
          path: path,
          viewedStateRaw: viewedState.rawValue,
          updatedAt: updatedAt
        )
        context.insert(row)
      }
      try context.save()
    } catch {
      logCacheFailure(
        op: "update_viewed",
        pullRequestID: pullRequestID,
        headRefOid: headRefOid,
        error: error
      )
    }
  }

  public func deleteAll(pullRequestID: String) {
    guard !pullRequestID.isEmpty else { return }
    do {
      let summaries = FetchDescriptor<CachedReviewFilesSummary>(
        predicate: #Predicate { $0.pullRequestID == pullRequestID }
      )
      for row in (try? context.fetch(summaries)) ?? [] { context.delete(row) }
      let files = FetchDescriptor<CachedReviewFile>(
        predicate: #Predicate { $0.pullRequestID == pullRequestID }
      )
      for row in (try? context.fetch(files)) ?? [] { context.delete(row) }
      let viewed = FetchDescriptor<CachedReviewFileViewedState>(
        predicate: #Predicate { $0.pullRequestID == pullRequestID }
      )
      for row in (try? context.fetch(viewed)) ?? [] { context.delete(row) }
      try context.save()
    } catch {
      logCacheFailure(
        op: "delete_pr",
        pullRequestID: pullRequestID,
        headRefOid: nil,
        error: error
      )
    }
  }

  public func deleteAll() {
    do {
      for row in (try? context.fetch(FetchDescriptor<CachedReviewFile>())) ?? [] {
        context.delete(row)
      }
      for row
        in (try? context.fetch(
          FetchDescriptor<CachedReviewFileViewedState>()
        )) ?? []
      {
        context.delete(row)
      }
      for row
        in (try? context.fetch(
          FetchDescriptor<CachedReviewFilesSummary>()
        )) ?? []
      {
        context.delete(row)
      }
      try context.save()
    } catch {
      logCacheFailure(op: "delete_all", pullRequestID: nil, headRefOid: nil, error: error)
    }
  }

  /// Drop file/viewed/summary rows whose summary's `fetchedAt` is older
  /// than `cutoff`. Used by the bootstrap vacuum task when the per-file
  /// row count exceeds the high-water mark.
  @discardableResult
  public func pruneStale(cutoff: Date) -> Int {
    var pruned = 0
    do {
      let staleSummaries = try context.fetch(
        FetchDescriptor<CachedReviewFilesSummary>(
          predicate: #Predicate { $0.fetchedAt < cutoff }
        )
      )
      let prIDs = staleSummaries.map(\.pullRequestID)
      for prID in prIDs {
        let fileDescriptor = FetchDescriptor<CachedReviewFile>(
          predicate: #Predicate { $0.pullRequestID == prID }
        )
        for row in (try? context.fetch(fileDescriptor)) ?? [] {
          context.delete(row)
          pruned += 1
        }
        let viewedDescriptor = FetchDescriptor<CachedReviewFileViewedState>(
          predicate: #Predicate { $0.pullRequestID == prID }
        )
        for row in (try? context.fetch(viewedDescriptor)) ?? [] {
          context.delete(row)
        }
      }
      for row in staleSummaries {
        context.delete(row)
      }
      try context.save()
    } catch {
      logCacheFailure(op: "prune_stale", pullRequestID: nil, headRefOid: nil, error: error)
    }
    return pruned
  }

  // MARK: - Internals

  private func upsertSummary(
    response: ReviewsFilesListResponse,
    fetchedAt: Date
  ) throws {
    let pullRequestID = response.pullRequestID
    let descriptor = FetchDescriptor<CachedReviewFilesSummary>(
      predicate: #Predicate { $0.pullRequestID == pullRequestID }
    )
    let additions = response.files.reduce(into: 0) { $0 += Int($1.additions) }
    let deletions = response.files.reduce(into: 0) { $0 += Int($1.deletions) }
    if let existing = try context.fetch(descriptor).first {
      existing.headRefOid = response.headRefOid
      existing.fetchedAt = fetchedAt
      existing.totalAdditions = additions
      existing.totalDeletions = deletions
      existing.fileCount = response.files.count
      existing.paginationComplete = response.paginationComplete
    } else {
      let row = CachedReviewFilesSummary(
        pullRequestID: response.pullRequestID,
        headRefOid: response.headRefOid,
        fetchedAt: fetchedAt,
        totalAdditions: additions,
        totalDeletions: deletions,
        fileCount: response.files.count,
        paginationComplete: response.paginationComplete
      )
      context.insert(row)
    }
  }

  private func replaceFiles(
    pullRequestID: String,
    headRefOid: String,
    files: [ReviewFile]
  ) throws {
    let existing = FetchDescriptor<CachedReviewFile>(
      predicate: #Predicate { $0.pullRequestID == pullRequestID }
    )
    for row in try context.fetch(existing) {
      context.delete(row)
    }
    for (index, file) in files.enumerated() {
      let row = CachedReviewFile(
        pullRequestID: pullRequestID,
        headRefOid: headRefOid,
        path: file.path,
        previousPath: file.previousPath,
        changeTypeRaw: file.changeType.rawValue,
        additions: Int(file.additions),
        deletions: Int(file.deletions),
        isBinary: file.isBinary,
        languageHintRaw: file.languageHint.rawValue,
        modeChange: file.modeChange,
        sortIndex: index
      )
      context.insert(row)
    }
  }

  private func replaceViewedStates(
    pullRequestID: String,
    headRefOid: String,
    files: [ReviewFile],
    updatedAt: Date
  ) throws {
    let existing = FetchDescriptor<CachedReviewFileViewedState>(
      predicate: #Predicate { $0.pullRequestID == pullRequestID }
    )
    for row in try context.fetch(existing) {
      context.delete(row)
    }
    for file in files {
      let row = CachedReviewFileViewedState(
        pullRequestID: pullRequestID,
        headRefOid: headRefOid,
        path: file.path,
        viewedStateRaw: file.viewerViewedState.rawValue,
        updatedAt: updatedAt
      )
      context.insert(row)
    }
  }

  private func logCacheFailure(
    op: String,
    pullRequestID: String?,
    headRefOid: String?,
    error: any Error
  ) {
    HarnessMonitorLogger.store.warning(
      """
      Review files cache op failed; \
      op=\(op, privacy: .public) \
      pull_request_id=\(pullRequestID ?? "-", privacy: .public) \
      head_ref_oid=\(headRefOid ?? "-", privacy: .public) \
      error=\(String(reflecting: error), privacy: .public)
      """
    )
  }
}

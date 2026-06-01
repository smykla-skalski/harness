import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
struct ReviewFilesCacheTests {
  private func makeCache() throws -> (ReviewFilesCache, ModelContext) {
    let container = try HarnessMonitorModelContainer.preview()
    let context = ModelContext(container)
    return (ReviewFilesCache(context: context), context)
  }

  private func makeResponse(
    pullRequestID: String = "pr-1",
    headRefOid: String = "head-a",
    files: [ReviewFile] = [],
    paginationComplete: Bool = true,
    fetchedAt: Date = Date(timeIntervalSince1970: 1_716_300_000)
  ) -> ReviewsFilesListResponse {
    ReviewsFilesListResponse(
      pullRequestID: pullRequestID,
      headRefOid: headRefOid,
      viewerCanMarkViewed: true,
      files: files,
      fetchedAt: fetchedAt.formatted(.iso8601),
      paginationComplete: paginationComplete,
      rateLimitSnapshot: nil
    )
  }

  private func makeFile(
    path: String,
    additions: UInt32 = 0,
    deletions: UInt32 = 0,
    viewed: ReviewFileViewedState = .unviewed,
    changeType: ReviewFileChangeType = .modified,
    isBinary: Bool = false,
    language: HarnessReviewFileLanguage = .generic,
    previousPath: String? = nil,
    modeChange: String? = nil
  ) -> ReviewFile {
    ReviewFile(
      path: path,
      previousPath: previousPath,
      changeType: changeType,
      additions: additions,
      deletions: deletions,
      viewerViewedState: viewed,
      isBinary: isBinary,
      languageHint: language,
      modeChange: modeChange
    )
  }

  @Test("record round-trips summary, files, and viewed states")
  func recordRoundTrips() throws {
    let (cache, _) = try makeCache()
    let response = makeResponse(
      files: [
        makeFile(path: "src/a.swift", additions: 5, deletions: 1, language: .swift),
        makeFile(
          path: "src/b.swift",
          additions: 2,
          deletions: 0,
          viewed: .viewed,
          changeType: .added,
          language: .swift
        ),
      ]
    )
    cache.record(response: response)

    let summary = cache.loadSummary(pullRequestID: "pr-1")
    #expect(summary?.headRefOid == "head-a")
    #expect(summary?.totalAdditions == 7)
    #expect(summary?.totalDeletions == 1)
    #expect(summary?.fileCount == 2)
    #expect(summary?.paginationComplete == true)

    let files = cache.loadFiles(pullRequestID: "pr-1", headRefOid: "head-a")
    #expect(files.map(\.path) == ["src/a.swift", "src/b.swift"])
    #expect(files.first?.languageHintRaw == HarnessReviewFileLanguage.swift.rawValue)

    let viewed = cache.loadViewedStates(pullRequestID: "pr-1", headRefOid: "head-a")
    #expect(
      viewed["src/a.swift"]?.viewedStateRaw == ReviewFileViewedState.unviewed.rawValue)
    #expect(
      viewed["src/b.swift"]?.viewedStateRaw == ReviewFileViewedState.viewed.rawValue)
  }

  @Test("record with new headRefOid replaces files atomically")
  func recordReplacesOnNewHead() throws {
    let (cache, context) = try makeCache()
    cache.record(
      response: makeResponse(
        headRefOid: "head-a",
        files: [
          makeFile(path: "src/a.swift", additions: 5),
          makeFile(path: "src/old.swift", additions: 1),
        ]
      )
    )
    cache.record(
      response: makeResponse(
        headRefOid: "head-b",
        files: [makeFile(path: "src/a.swift", additions: 9)]
      )
    )

    let filesA = cache.loadFiles(pullRequestID: "pr-1", headRefOid: "head-a")
    let filesB = cache.loadFiles(pullRequestID: "pr-1", headRefOid: "head-b")
    #expect(filesA.isEmpty)
    #expect(filesB.map(\.path) == ["src/a.swift"])
    #expect(filesB.first?.additions == 9)

    let allFiles = try context.fetch(FetchDescriptor<CachedReviewFile>())
    #expect(allFiles.count == 1)
    #expect(cache.loadSummary(pullRequestID: "pr-1")?.headRefOid == "head-b")
  }

  @Test("paginationComplete=false propagates onto the summary")
  func paginationCompleteFalsePropagates() throws {
    let (cache, _) = try makeCache()
    cache.record(
      response: makeResponse(
        files: [makeFile(path: "a")],
        paginationComplete: false
      )
    )
    #expect(cache.loadSummary(pullRequestID: "pr-1")?.paginationComplete == false)
  }

  @Test("updateViewedState upserts the (PR, head, path) row")
  func updateViewedStateUpserts() throws {
    let (cache, context) = try makeCache()
    cache.record(
      response: makeResponse(
        files: [makeFile(path: "src/a.swift", viewed: .unviewed)]
      )
    )

    cache.updateViewedState(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      viewedState: .viewed
    )
    cache.updateViewedState(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      viewedState: .dismissed
    )

    let rows = try context.fetch(FetchDescriptor<CachedReviewFileViewedState>())
    #expect(rows.count == 1)
    #expect(rows.first?.viewedStateRaw == ReviewFileViewedState.dismissed.rawValue)
  }

  @Test("updateViewedState inserts a new row when none exists")
  func updateViewedStateInsertsWhenMissing() throws {
    let (cache, _) = try makeCache()
    cache.updateViewedState(
      pullRequestID: "pr-2",
      headRefOid: "head-z",
      path: "src/new.swift",
      viewedState: .viewed
    )
    let states = cache.loadViewedStates(pullRequestID: "pr-2", headRefOid: "head-z")
    #expect(
      states["src/new.swift"]?.viewedStateRaw == ReviewFileViewedState.viewed.rawValue)
  }

  @Test("deleteAll(pullRequestID:) scopes the deletion to that PR")
  func deleteAllByPullRequestIDScoped() throws {
    let (cache, context) = try makeCache()
    cache.record(
      response: makeResponse(
        pullRequestID: "pr-1",
        files: [makeFile(path: "a"), makeFile(path: "b")]
      )
    )
    cache.record(
      response: makeResponse(
        pullRequestID: "pr-2",
        files: [makeFile(path: "c")]
      )
    )

    cache.deleteAll(pullRequestID: "pr-1")

    let files = try context.fetch(FetchDescriptor<CachedReviewFile>())
    #expect(files.count == 1)
    #expect(files.first?.pullRequestID == "pr-2")
    #expect(cache.loadSummary(pullRequestID: "pr-1") == nil)
    #expect(cache.loadSummary(pullRequestID: "pr-2") != nil)
  }

  @Test("pruneStale drops summary/file/viewed rows older than the cutoff")
  func pruneStaleDropsOld() throws {
    let (cache, context) = try makeCache()
    let oldFetch = Date(timeIntervalSince1970: 1_000_000)
    let newFetch = Date(timeIntervalSince1970: 1_716_300_000)
    let cutoff = Date(timeIntervalSince1970: 1_500_000)

    cache.record(
      response: makeResponse(
        pullRequestID: "pr-old",
        files: [makeFile(path: "stale.swift")],
        fetchedAt: oldFetch
      )
    )
    cache.record(
      response: makeResponse(
        pullRequestID: "pr-new",
        files: [makeFile(path: "fresh.swift")],
        fetchedAt: newFetch
      )
    )

    let pruned = cache.pruneStale(cutoff: cutoff)
    #expect(pruned == 1)

    let summaries = try context.fetch(
      FetchDescriptor<CachedReviewFilesSummary>()
    )
    #expect(summaries.map(\.pullRequestID) == ["pr-new"])
    let files = try context.fetch(FetchDescriptor<CachedReviewFile>())
    #expect(files.map(\.pullRequestID) == ["pr-new"])
  }

  @Test("countCachedFiles reports the total per-file row count")
  func countCachedFiles() throws {
    let (cache, _) = try makeCache()
    cache.record(
      response: makeResponse(
        pullRequestID: "pr-1",
        files: [makeFile(path: "a"), makeFile(path: "b")]
      )
    )
    cache.record(
      response: makeResponse(
        pullRequestID: "pr-2",
        files: [makeFile(path: "c")]
      )
    )
    #expect(cache.countCachedFiles() == 3)
  }

  @Test("record ignores empty pullRequestID or headRefOid")
  func recordIgnoresEmptyIdentifiers() throws {
    let (cache, context) = try makeCache()
    cache.record(response: makeResponse(pullRequestID: ""))
    cache.record(response: makeResponse(headRefOid: ""))
    #expect(try context.fetch(FetchDescriptor<CachedReviewFilesSummary>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<CachedReviewFile>()).isEmpty)
  }
}

@MainActor
struct HarnessMonitorSchemaV21MigrationTests {
  @Test("V21 container starts empty for the three new dependency-files tables")
  func newTablesStartEmpty() throws {
    let container = try HarnessMonitorModelContainer.preview()
    let context = ModelContext(container)
    #expect(try context.fetch(FetchDescriptor<CachedReviewFilesSummary>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<CachedReviewFile>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<CachedReviewFileViewedState>()).isEmpty)
  }

  @Test("HarnessMonitorCurrentSchema is V25")
  func currentSchemaIsV25() {
    #expect(HarnessMonitorCurrentSchema.versionIdentifier == Schema.Version(25, 0, 0))
  }

  @Test("Pre-existing V20 entities remain reachable under V21")
  func v20EntitiesStillReachable() throws {
    let container = try HarnessMonitorModelContainer.preview()
    let context = ModelContext(container)
    let cache = ReviewsRepoSyncStateCache(context: context)
    cache.recordSyncedAt(preferencesHash: "hash-a", repository: "acme/api")
    #expect(cache.loadStates(preferencesHash: "hash-a").count == 1)
  }
}

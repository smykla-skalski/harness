import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("V21 -> V22 Reviews rename migration round-trip")
struct HarnessMonitorMigrationV21ToV22IntegrationTests {
  @Test("All seven CachedDependency* rows promote to CachedReview* equivalents")
  func legacyRowsMigrateAcrossEntityBoundary() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let environment = HarnessMonitorEnvironment(
      values: ["XDG_DATA_HOME": root.path],
      homeDirectory: root
    )
    let harnessRoot = HarnessMonitorPaths.harnessRoot(using: environment)
    try FileManager.default.createDirectory(
      at: harnessRoot, withIntermediateDirectories: true
    )

    let storeURL = harnessRoot.appendingPathComponent("harness-cache.store")
    let snapshotAt = Date(timeIntervalSince1970: 1_700_000_000)
    let viewedAt = Date(timeIntervalSince1970: 1_700_000_500)

    try seedV21Fixture(
      at: storeURL, snapshotAt: snapshotAt, viewedAt: viewedAt
    )

    let container = try HarnessMonitorModelContainer.live(using: environment)
    let context = container.mainContext

    let snapshots = try context.fetch(FetchDescriptor<CachedReviewsSnapshot>())
    #expect(snapshots.count == 1)
    #expect(snapshots.first?.preferencesHash == "prefs-hash")
    #expect(snapshots.first?.cachedAt == snapshotAt)
    #expect(snapshots.first?.responseData == Data("body".utf8))

    let labels = try context.fetch(FetchDescriptor<CachedReviewRepositoryLabels>())
    #expect(labels.count == 1)
    #expect(labels.first?.repository == "octo/repo")
    #expect(labels.first?.labelsData == Data("[]".utf8))

    let usage = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(usage.count == 1)
    #expect(usage.first?.repository == "octo/repo")
    #expect(usage.first?.label == "renovate")
    #expect(usage.first?.usageCount == 3)

    let sync = try context.fetch(FetchDescriptor<CachedReviewsRepoSyncState>())
    #expect(sync.count == 1)
    #expect(sync.first?.preferencesHash == "prefs-hash")
    #expect(sync.first?.repository == "octo/repo")

    let summaries = try context.fetch(FetchDescriptor<CachedReviewFilesSummary>())
    #expect(summaries.count == 1)
    #expect(summaries.first?.pullRequestID == "octo/repo#1")
    #expect(summaries.first?.fileCount == 1)

    let files = try context.fetch(FetchDescriptor<CachedReviewFile>())
    #expect(files.count == 1)
    #expect(files.first?.path == "Cargo.toml")
    #expect(files.first?.additions == 7)
    #expect(files.first?.deletions == 1)

    let viewedStates = try context.fetch(
      FetchDescriptor<CachedReviewFileViewedState>()
    )
    #expect(viewedStates.count == 1)
    #expect(viewedStates.first?.path == "Cargo.toml")
    #expect(viewedStates.first?.viewedStateRaw == "viewed")
    #expect(viewedStates.first?.updatedAt == viewedAt)

    let leftoverSnapshots = try context.fetch(
      FetchDescriptor<CachedDependencyUpdatesSnapshot>()
    )
    #expect(leftoverSnapshots.isEmpty)
    let leftoverFiles = try context.fetch(
      FetchDescriptor<CachedDependencyUpdateFile>()
    )
    #expect(leftoverFiles.isEmpty)
  }

  @Test("Reopening an already-migrated store does not re-run the stage")
  func secondOpenIsANoOp() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let environment = HarnessMonitorEnvironment(
      values: ["XDG_DATA_HOME": root.path],
      homeDirectory: root
    )
    let harnessRoot = HarnessMonitorPaths.harnessRoot(using: environment)
    try FileManager.default.createDirectory(
      at: harnessRoot, withIntermediateDirectories: true
    )

    let storeURL = harnessRoot.appendingPathComponent("harness-cache.store")
    try seedV21Fixture(
      at: storeURL, snapshotAt: .now, viewedAt: .now
    )

    let firstOpen = try HarnessMonitorModelContainer.live(using: environment)
    let firstCount = try firstOpen.mainContext.fetch(
      FetchDescriptor<CachedReviewsSnapshot>()
    ).count
    #expect(firstCount == 1)

    let secondOpen = try HarnessMonitorModelContainer.live(using: environment)
    let secondContext = secondOpen.mainContext
    let snapshotsAfterReopen = try secondContext.fetch(
      FetchDescriptor<CachedReviewsSnapshot>()
    )
    #expect(snapshotsAfterReopen.count == 1)
    let leftoverSnapshots = try secondContext.fetch(
      FetchDescriptor<CachedDependencyUpdatesSnapshot>()
    )
    #expect(leftoverSnapshots.isEmpty)
  }
}

@MainActor
private func seedV21Fixture(
  at url: URL,
  snapshotAt: Date,
  viewedAt: Date
) throws {
  let schema = Schema(versionedSchema: HarnessMonitorSchemaV21.self)
  let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)
  let container = try ModelContainer(for: schema, configurations: [config])
  let context = container.mainContext

  context.insert(
    CachedDependencyUpdatesSnapshot(
      preferencesHash: "prefs-hash",
      cachedAt: snapshotAt,
      responseData: Data("body".utf8)
    )
  )
  context.insert(
    CachedDependencyRepositoryLabels(
      repository: "octo/repo",
      cachedAt: snapshotAt,
      labelsData: Data("[]".utf8)
    )
  )
  context.insert(
    CachedDependencyLabelUsage(
      repository: "octo/repo",
      label: "renovate",
      usageCount: 3,
      lastUsedAt: snapshotAt
    )
  )
  context.insert(
    CachedDependencyUpdatesRepoSyncState(
      preferencesHash: "prefs-hash",
      repository: "octo/repo",
      lastSyncedAt: snapshotAt
    )
  )
  context.insert(
    CachedDependencyUpdateFilesSummary(
      pullRequestID: "octo/repo#1",
      headRefOid: "deadbeef",
      fetchedAt: snapshotAt,
      totalAdditions: 7,
      totalDeletions: 1,
      fileCount: 1,
      paginationComplete: true
    )
  )
  context.insert(
    CachedDependencyUpdateFile(
      pullRequestID: "octo/repo#1",
      headRefOid: "deadbeef",
      path: "Cargo.toml",
      previousPath: nil,
      changeTypeRaw: "modified",
      additions: 7,
      deletions: 1,
      isBinary: false,
      languageHintRaw: "toml",
      modeChange: nil,
      sortIndex: 0
    )
  )
  context.insert(
    CachedDependencyUpdateFileViewedState(
      pullRequestID: "octo/repo#1",
      headRefOid: "deadbeef",
      path: "Cargo.toml",
      viewedStateRaw: "viewed",
      updatedAt: viewedAt
    )
  )

  try context.save()
}

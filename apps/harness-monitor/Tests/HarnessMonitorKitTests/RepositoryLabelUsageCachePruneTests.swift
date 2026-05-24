import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
struct RepositoryLabelUsageCachePruneTests {
  private func makeCache() throws -> (RepositoryLabelUsageCache, ModelContext) {
    let container = try HarnessMonitorModelContainer.preview()
    let context = ModelContext(container)
    return (RepositoryLabelUsageCache(context: context), context)
  }

  @Test("pruneStale caps rows per repository at the lowest-rank tail")
  func pruneStaleCapsLowestRankTailPerRepository() throws {
    let (cache, context) = try makeCache()
    let repository = "owner/repo"

    for index in 0..<60 {
      let row = CachedReviewLabelUsage(
        repository: repository,
        label: "label-\(index)",
        usageCount: index + 1
      )
      context.insert(row)
    }
    try context.save()

    cache.pruneStale(perRepoCap: 50)

    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.count == 50)
    let remainingLabels = Set(rows.map(\.label))
    for index in 0..<10 {
      #expect(!remainingLabels.contains("label-\(index)"))
    }
    for index in 10..<60 {
      #expect(remainingLabels.contains("label-\(index)"))
    }
  }

  @Test("pruneStale isolates each repository's cap independently")
  func pruneStaleIsolatesEachRepositoryIndependently() throws {
    let (cache, context) = try makeCache()
    let repositories = ["owner/a", "owner/b", "owner/c"]

    for repository in repositories {
      for index in 0..<10 {
        let row = CachedReviewLabelUsage(
          repository: repository,
          label: "label-\(index)",
          usageCount: index + 1
        )
        context.insert(row)
      }
    }
    try context.save()

    cache.pruneStale(perRepoCap: 50)

    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.count == 30)
  }

  @Test("pruneStale is a no-op when every repository is below the cap")
  func pruneStaleIsNoopWhenBelowCap() throws {
    let (cache, context) = try makeCache()
    for index in 0..<10 {
      let row = CachedReviewLabelUsage(
        repository: "owner/repo",
        label: "label-\(index)",
        usageCount: index + 1
      )
      context.insert(row)
    }
    try context.save()

    cache.pruneStale(perRepoCap: 50)

    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.count == 10)
  }

  @Test("pruneStale breaks count ties by most-recent lastUsedAt")
  func pruneStaleBreaksCountTiesByMostRecentLastUsedAt() throws {
    let (cache, context) = try makeCache()
    let repository = "owner/repo"
    let now = Date()

    for index in 0..<3 {
      let row = CachedReviewLabelUsage(
        repository: repository,
        label: "label-\(index)",
        usageCount: 1,
        lastUsedAt: now.addingTimeInterval(TimeInterval(index))
      )
      context.insert(row)
    }
    try context.save()

    cache.pruneStale(perRepoCap: 2)

    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.count == 2)
    let remainingLabels = Set(rows.map(\.label))
    #expect(remainingLabels.contains("label-2"))
    #expect(remainingLabels.contains("label-1"))
    #expect(!remainingLabels.contains("label-0"))
  }
}

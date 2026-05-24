import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
struct RepositoryLabelUsageCacheTests {
  private func makeCache() throws -> (RepositoryLabelUsageCache, ModelContext) {
    let container = try HarnessMonitorModelContainer.preview()
    let context = ModelContext(container)
    return (RepositoryLabelUsageCache(context: context), context)
  }

  @Test("recordUse upserts and increments per (repository, label)")
  func recordUseUpsertsAndIncrements() throws {
    let (cache, context) = try makeCache()

    cache.recordUse(repository: "owner/repo", label: "renovate")
    cache.recordUse(repository: "owner/repo", label: "renovate")
    cache.recordUse(repository: "owner/repo", label: "dependencies")

    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.count == 2)
    let renovate = try #require(rows.first { $0.label == "renovate" })
    let dependencies = try #require(rows.first { $0.label == "dependencies" })
    #expect(renovate.usageCount == 2)
    #expect(dependencies.usageCount == 1)
  }

  @Test("recordUse ignores empty repository or label")
  func recordUseIgnoresEmptyKeys() throws {
    let (cache, context) = try makeCache()

    cache.recordUse(repository: "", label: "renovate")
    cache.recordUse(repository: "owner/repo", label: "")

    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.isEmpty)
  }

  @Test("topUsed returns labels ordered by count desc, capped at limit")
  func topUsedRanksByCountDescending() throws {
    let (cache, _) = try makeCache()
    let repository = "owner/repo"

    for _ in 0..<3 { cache.recordUse(repository: repository, label: "renovate") }
    for _ in 0..<5 { cache.recordUse(repository: repository, label: "dependencies") }
    cache.recordUse(repository: repository, label: "chore")

    let top = cache.topUsed(repositories: [repository], limit: 2)
    #expect(top == ["dependencies", "renovate"])
  }

  @Test("topUsed sums counts across repositories")
  func topUsedAggregatesAcrossRepositories() throws {
    let (cache, _) = try makeCache()

    cache.recordUse(repository: "owner/alpha", label: "renovate")
    cache.recordUse(repository: "owner/alpha", label: "renovate")
    cache.recordUse(repository: "owner/beta", label: "renovate")
    cache.recordUse(repository: "owner/alpha", label: "release")
    cache.recordUse(repository: "owner/beta", label: "release")
    cache.recordUse(repository: "owner/beta", label: "release")

    let top = cache.topUsed(repositories: ["owner/alpha", "owner/beta"], limit: 5)
    // Both end at 3 total; ties break on most-recent lastUsedAt, then case-insensitive name.
    #expect(top.count == 2)
    #expect(Set(top) == Set(["renovate", "release"]))
  }

  @Test("topUsed returns empty for unknown repositories or non-positive limit")
  func topUsedHandlesEdgeCases() throws {
    let (cache, _) = try makeCache()
    cache.recordUse(repository: "owner/repo", label: "renovate")

    #expect(cache.topUsed(repositories: [], limit: 5).isEmpty)
    #expect(cache.topUsed(repositories: ["owner/repo"], limit: 0).isEmpty)
    #expect(cache.topUsed(repositories: ["owner/unknown"], limit: 5).isEmpty)
  }

  @Test("deleteAll drops every row")
  func deleteAllDropsRows() throws {
    let (cache, context) = try makeCache()
    cache.recordUse(repository: "owner/repo", label: "renovate")
    cache.recordUse(repository: "owner/repo", label: "release")

    cache.deleteAll()

    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.isEmpty)
  }
}

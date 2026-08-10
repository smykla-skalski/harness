import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
struct RepositoryLabelUsageCacheTests {
  private func makePersistence() throws -> (
    ModelContainer,
    RepositoryLabelUsagePersistenceWorker
  ) {
    let container = try HarnessMonitorModelContainer.preview()
    return (container, RepositoryLabelUsagePersistenceWorker(modelContainer: container))
  }

  @Test("recordUse upserts and increments per (repository, label)")
  func recordUseUpsertsAndIncrements() async throws {
    let (container, persistence) = try makePersistence()

    await persistence.recordUses(repositories: ["owner/repo"], label: "renovate")
    await persistence.recordUses(repositories: ["owner/repo"], label: "renovate")
    await persistence.recordUses(repositories: ["owner/repo"], label: "dependencies")

    let context = ModelContext(container)
    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.count == 2)
    let renovate = try #require(rows.first { $0.label == "renovate" })
    let dependencies = try #require(rows.first { $0.label == "dependencies" })
    #expect(renovate.usageCount == 2)
    #expect(dependencies.usageCount == 1)
  }

  @Test("recordUse ignores empty repository or label")
  func recordUseIgnoresEmptyKeys() async throws {
    let (container, persistence) = try makePersistence()

    await persistence.recordUses(repositories: [""], label: "renovate")
    await persistence.recordUses(repositories: ["owner/repo"], label: "")

    let context = ModelContext(container)
    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.isEmpty)
  }

  @Test("topUsed returns labels ordered by count desc, capped at limit")
  func topUsedRanksByCountDescending() async throws {
    let (container, persistence) = try makePersistence()
    let repository = "owner/repo"

    for _ in 0..<3 {
      await persistence.recordUses(repositories: [repository], label: "renovate")
    }
    for _ in 0..<5 {
      await persistence.recordUses(repositories: [repository], label: "dependencies")
    }
    await persistence.recordUses(repositories: [repository], label: "chore")

    let cache = RepositoryLabelUsageCache(context: ModelContext(container))
    let top = cache.topUsed(repositories: [repository], limit: 2)
    #expect(top == ["dependencies", "renovate"])
  }

  @Test("topUsed sums counts across repositories")
  func topUsedAggregatesAcrossRepositories() async throws {
    let (container, persistence) = try makePersistence()

    await persistence.recordUses(repositories: ["owner/alpha"], label: "renovate")
    await persistence.recordUses(repositories: ["owner/alpha"], label: "renovate")
    await persistence.recordUses(repositories: ["owner/beta"], label: "renovate")
    await persistence.recordUses(repositories: ["owner/alpha"], label: "release")
    await persistence.recordUses(repositories: ["owner/beta"], label: "release")
    await persistence.recordUses(repositories: ["owner/beta"], label: "release")

    let cache = RepositoryLabelUsageCache(context: ModelContext(container))
    let top = cache.topUsed(repositories: ["owner/alpha", "owner/beta"], limit: 5)
    // Both end at 3 total; ties break on most-recent lastUsedAt, then case-insensitive name.
    #expect(top.count == 2)
    #expect(Set(top) == Set(["renovate", "release"]))
  }

  @Test("topUsed returns empty for unknown repositories or non-positive limit")
  func topUsedHandlesEdgeCases() async throws {
    let (container, persistence) = try makePersistence()
    await persistence.recordUses(repositories: ["owner/repo"], label: "renovate")
    let cache = RepositoryLabelUsageCache(context: ModelContext(container))

    #expect(cache.topUsed(repositories: [], limit: 5).isEmpty)
    #expect(cache.topUsed(repositories: ["owner/repo"], limit: 0).isEmpty)
    #expect(cache.topUsed(repositories: ["owner/unknown"], limit: 5).isEmpty)
  }

  @Test("deleteAll drops every row")
  func deleteAllDropsRows() async throws {
    let (container, persistence) = try makePersistence()
    await persistence.recordUses(repositories: ["owner/repo"], label: "renovate")
    await persistence.recordUses(repositories: ["owner/repo"], label: "release")

    await persistence.deleteAll()

    let context = ModelContext(container)
    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.isEmpty)
  }
}

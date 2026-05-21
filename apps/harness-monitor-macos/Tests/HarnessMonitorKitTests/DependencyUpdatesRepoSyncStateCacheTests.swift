import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
struct DependencyUpdatesRepoSyncStateCacheTests {
  private func makeCache() throws -> (
    DependencyUpdatesRepoSyncStateCache, ModelContext
  ) {
    let container = try HarnessMonitorModelContainer.preview()
    let context = ModelContext(container)
    return (DependencyUpdatesRepoSyncStateCache(context: context), context)
  }

  @Test("recordSyncedAt + loadStates round-trips a single repository")
  func recordAndLoadRoundTrip() throws {
    let (cache, _) = try makeCache()
    let when = Date(timeIntervalSince1970: 1_716_300_000)

    cache.recordSyncedAt(
      preferencesHash: "hash-a",
      repository: "acme/api",
      syncedAt: when
    )

    let states = cache.loadStates(preferencesHash: "hash-a")
    #expect(states.count == 1)
    #expect(states["acme/api"] == when)
  }

  @Test("recordSyncedAt upserts on same (hash, repository) key")
  func recordSyncedAtUpserts() throws {
    let (cache, context) = try makeCache()
    let first = Date(timeIntervalSince1970: 1_716_300_000)
    let second = Date(timeIntervalSince1970: 1_716_300_999)

    cache.recordSyncedAt(
      preferencesHash: "hash-a",
      repository: "acme/api",
      syncedAt: first
    )
    cache.recordSyncedAt(
      preferencesHash: "hash-a",
      repository: "acme/api",
      syncedAt: second
    )

    let rows = try context.fetch(
      FetchDescriptor<CachedDependencyUpdatesRepoSyncState>()
    )
    #expect(rows.count == 1)
    #expect(rows.first?.lastSyncedAt == second)
  }

  @Test("loadStates isolates rows by preferencesHash bucket")
  func loadStatesIsolatesByHash() throws {
    let (cache, _) = try makeCache()

    cache.recordSyncedAt(preferencesHash: "hash-a", repository: "acme/api")
    cache.recordSyncedAt(preferencesHash: "hash-a", repository: "acme/web")
    cache.recordSyncedAt(preferencesHash: "hash-b", repository: "acme/api")

    let a = cache.loadStates(preferencesHash: "hash-a")
    let b = cache.loadStates(preferencesHash: "hash-b")
    #expect(Set(a.keys) == Set(["acme/api", "acme/web"]))
    #expect(Set(b.keys) == Set(["acme/api"]))
  }

  @Test("recordSyncedAt ignores empty hash or repository")
  func recordSyncedAtIgnoresEmptyKeys() throws {
    let (cache, context) = try makeCache()

    cache.recordSyncedAt(preferencesHash: "", repository: "acme/api")
    cache.recordSyncedAt(preferencesHash: "hash-a", repository: "")

    let rows = try context.fetch(
      FetchDescriptor<CachedDependencyUpdatesRepoSyncState>()
    )
    #expect(rows.isEmpty)
  }

  @Test("loadStates preserves relative ordering so stalest-first works")
  func loadStatesPreservesOrderingHint() throws {
    let (cache, _) = try makeCache()
    let older = Date(timeIntervalSince1970: 1_716_300_000)
    let newer = Date(timeIntervalSince1970: 1_716_300_999)

    cache.recordSyncedAt(
      preferencesHash: "hash-a",
      repository: "acme/api",
      syncedAt: newer
    )
    cache.recordSyncedAt(
      preferencesHash: "hash-a",
      repository: "acme/web",
      syncedAt: older
    )

    let states = cache.loadStates(preferencesHash: "hash-a")
    let sorted = states.sorted { $0.value < $1.value }.map(\.key)
    #expect(sorted == ["acme/web", "acme/api"])
  }

  @Test("deleteAll(preferencesHash:) drops only that bucket")
  func deleteAllByHashScoped() throws {
    let (cache, _) = try makeCache()
    cache.recordSyncedAt(preferencesHash: "hash-a", repository: "acme/api")
    cache.recordSyncedAt(preferencesHash: "hash-a", repository: "acme/web")
    cache.recordSyncedAt(preferencesHash: "hash-b", repository: "acme/api")

    cache.deleteAll(preferencesHash: "hash-a")

    #expect(cache.loadStates(preferencesHash: "hash-a").isEmpty)
    #expect(cache.loadStates(preferencesHash: "hash-b").count == 1)
  }

  @Test("deleteAll drops every row across buckets")
  func deleteAllDropsEverything() throws {
    let (cache, context) = try makeCache()
    cache.recordSyncedAt(preferencesHash: "hash-a", repository: "acme/api")
    cache.recordSyncedAt(preferencesHash: "hash-b", repository: "acme/web")

    cache.deleteAll()

    let rows = try context.fetch(
      FetchDescriptor<CachedDependencyUpdatesRepoSyncState>()
    )
    #expect(rows.isEmpty)
  }
}

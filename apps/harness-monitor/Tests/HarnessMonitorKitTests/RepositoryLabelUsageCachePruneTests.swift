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

  @Test("Bootstrap schedules cache maintenance outside the main actor")
  func bootstrapSchedulesCacheMaintenanceOutsideMainActor() throws {
    let monitorRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let bootstrapURL = monitorRoot.appendingPathComponent(
      "Sources/HarnessMonitorKit/Stores/HarnessMonitorStore+Bootstrap.swift"
    )
    let source = try String(contentsOf: bootstrapURL, encoding: .utf8)

    #expect(source.contains("scheduleRepositoryLabelUsageCachePrune()"))
    #expect(source.contains("Task.detached(priority: .background)"))
    #expect(
      source.contains(
        "await worker.pruneStale()"
      )
    )
    #expect(source.contains("nonisolated private static func runReviewFilesVacuum("))
  }

  @Test("pruneStale caps rows per repository at the lowest-rank tail")
  func pruneStaleCapsLowestRankTailPerRepository() throws {
    let (_, context) = try makeCache()
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

    RepositoryLabelUsageCacheMaintenance(context: context).pruneStale(perRepoCap: 50)

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
    let (_, context) = try makeCache()
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

    RepositoryLabelUsageCacheMaintenance(context: context).pruneStale(perRepoCap: 50)

    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.count == 30)
  }

  @Test("pruneStale is a no-op when every repository is below the cap")
  func pruneStaleIsNoopWhenBelowCap() throws {
    let (_, context) = try makeCache()
    for index in 0..<10 {
      let row = CachedReviewLabelUsage(
        repository: "owner/repo",
        label: "label-\(index)",
        usageCount: index + 1
      )
      context.insert(row)
    }
    try context.save()

    RepositoryLabelUsageCacheMaintenance(context: context).pruneStale(perRepoCap: 50)

    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.count == 10)
  }

  @Test("pruneStale breaks count ties by most-recent lastUsedAt")
  func pruneStaleBreaksCountTiesByMostRecentLastUsedAt() throws {
    let (_, context) = try makeCache()
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

    RepositoryLabelUsageCacheMaintenance(context: context).pruneStale(perRepoCap: 2)

    let rows = try context.fetch(FetchDescriptor<CachedReviewLabelUsage>())
    #expect(rows.count == 2)
    let remainingLabels = Set(rows.map(\.label))
    #expect(remainingLabels.contains("label-2"))
    #expect(remainingLabels.contains("label-1"))
    #expect(!remainingLabels.contains("label-0"))
  }

  @Test("Background prune never blocks the main actor")
  func backgroundPruneDoesNotBlockMainActor() async throws {
    let container = try HarnessMonitorModelContainer.preview()
    let gate = RepositoryLabelUsagePruneGate()
    let worker = RepositoryLabelUsagePersistenceWorker(
      modelContainer: container,
      beforePrune: { await gate.blockPrune() }
    )
    let prune = Task {
      await worker.pruneStale()
    }
    await gate.waitUntilBlocked()

    var mainActorAdvanced = false
    await Task { @MainActor in
      mainActorAdvanced = true
    }.value

    #expect(mainActorAdvanced)
    await gate.releasePrune()
    await prune.value
  }
}

private actor RepositoryLabelUsagePruneGate {
  private var isBlocked = false
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []

  func blockPrune() async {
    isBlocked = true
    let arrivals = arrivalContinuations
    arrivalContinuations.removeAll()
    for arrival in arrivals {
      arrival.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilBlocked() async {
    guard !isBlocked else { return }
    await withCheckedContinuation { continuation in
      arrivalContinuations.append(continuation)
    }
  }

  func releasePrune() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

import Foundation
import SwiftData

/// Retention compaction for `SupervisorEvent` and `Decision`.
public final class SupervisorAuditRetention {
  public struct CompactionResult: Sendable, Hashable {
    public let deletedEvents: Int
    public let deletedDecisions: Int

    public var totalDeleted: Int {
      deletedEvents + deletedDecisions
    }

    public init(deletedEvents: Int, deletedDecisions: Int) {
      self.deletedEvents = deletedEvents
      self.deletedDecisions = deletedDecisions
    }
  }

  public static let defaultRetention: TimeInterval = 14 * 24 * 60 * 60
  public static let schedulerIdentifier = "io.harnessmonitor.supervisor.retention"

  private let container: ModelContainer
  private let clock: @Sendable () -> Date

  public init(
    container: ModelContainer,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.container = container
    self.clock = clock
  }

  public func compactOlderThan(_ age: TimeInterval) async throws -> CompactionResult {
    let cutoff = clock().addingTimeInterval(-age)
    let context = ModelContext(container)
    context.autosaveEnabled = false

    let deletedEvents = try deleteEvents(before: cutoff, in: context)
    let deletedDecisions = try deleteDecisions(before: cutoff, in: context)
    guard deletedEvents > 0 || deletedDecisions > 0 else {
      return CompactionResult(deletedEvents: 0, deletedDecisions: 0)
    }

    try context.save()
    return CompactionResult(
      deletedEvents: deletedEvents,
      deletedDecisions: deletedDecisions
    )
  }

  private func deleteEvents(before cutoff: Date, in context: ModelContext) throws -> Int {
    let descriptor = FetchDescriptor<SupervisorEvent>(
      predicate: #Predicate<SupervisorEvent> { $0.createdAt < cutoff }
    )
    let rows = try context.fetch(descriptor)
    guard !rows.isEmpty else { return 0 }
    rows.forEach(context.delete)
    return rows.count
  }

  private func deleteDecisions(before cutoff: Date, in context: ModelContext) throws -> Int {
    let descriptor = FetchDescriptor<Decision>(
      predicate: #Predicate<Decision> { $0.createdAt < cutoff }
    )
    let rows = try context.fetch(descriptor)
    guard !rows.isEmpty else { return 0 }
    rows.forEach(context.delete)
    return rows.count
  }
}

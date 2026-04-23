import Foundation
import SwiftData

/// Retention compaction for `SupervisorEvent` and `Decision`.
public final class SupervisorAuditRetention: @unchecked Sendable {
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
  public static let defaultCompactionInterval: TimeInterval = 24 * 60 * 60
  public static let schedulerIdentifier = "io.harnessmonitor.supervisor.retention"

  public private(set) var isBackgroundActivityScheduled: Bool = false

  private let container: ModelContainer
  private let clock: @Sendable () -> Date
  private let interval: TimeInterval
  private let tolerance: TimeInterval
  private let identifier: String
  private var scheduler: NSBackgroundActivityScheduler?

  public init(
    container: ModelContainer,
    clock: @escaping @Sendable () -> Date = { Date() },
    interval: TimeInterval = defaultCompactionInterval,
    tolerance: TimeInterval = 60 * 60,
    identifier: String = schedulerIdentifier
  ) {
    self.container = container
    self.clock = clock
    self.interval = interval
    self.tolerance = tolerance
    self.identifier = identifier
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

  public func startBackgroundCompaction() {
    stopBackgroundCompaction()

    guard runInBackgroundEnabled else {
      HarnessMonitorLogger.supervisorInfo(
        "supervisor.audit_retention.background_skipped reason=preference_disabled"
      )
      return
    }

    let activity = NSBackgroundActivityScheduler(identifier: identifier)
    activity.repeats = true
    activity.interval = interval
    activity.tolerance = normalizedTolerance
    activity.qualityOfService = .utility
    activity.schedule { [weak self] completion in
      guard let self else {
        completion(.deferred)
        return
      }
      HarnessMonitorLogger.supervisorDebug("supervisor.audit_retention.background_tick fired")
      Task {
        do {
          let result = try await self.forceCompaction()
          HarnessMonitorLogger.supervisorInfo(
            """
            supervisor.audit_retention.compacted deleted_events=\(result.deletedEvents) \
            deleted_decisions=\(result.deletedDecisions)
            """
          )
          completion(.finished)
        } catch {
          HarnessMonitorLogger.supervisorWarning(
            """
            supervisor.audit_retention.compaction_failed \
            error=\(String(describing: error))
            """
          )
          completion(.deferred)
        }
      }
    }

    scheduler = activity
    isBackgroundActivityScheduled = true
    let intervalValue = interval
    HarnessMonitorLogger.supervisorInfo(
      "supervisor.audit_retention.background_started interval=\(intervalValue)"
    )
  }

  public func stopBackgroundCompaction() {
    guard let activity = scheduler else {
      isBackgroundActivityScheduled = false
      return
    }
    activity.invalidate()
    scheduler = nil
    isBackgroundActivityScheduled = false
    HarnessMonitorLogger.supervisorInfo("supervisor.audit_retention.background_stopped")
  }

  public func forceCompaction() async throws -> CompactionResult {
    try await compactOlderThan(Self.defaultRetention)
  }

  private func deleteEvents(before cutoff: Date, in context: ModelContext) throws -> Int {
    try deleteRows(
      in: context,
      makeDescriptor: {
        FetchDescriptor<SupervisorEvent>(
          predicate: #Predicate<SupervisorEvent> { $0.createdAt < cutoff },
          sortBy: [
            SortDescriptor(\.createdAt, order: .forward),
            SortDescriptor(\.id, order: .forward),
          ]
        )
      }
    )
  }

  private func deleteDecisions(before cutoff: Date, in context: ModelContext) throws -> Int {
    try deleteRows(
      in: context,
      makeDescriptor: {
        FetchDescriptor<Decision>(
          predicate: #Predicate<Decision> { $0.createdAt < cutoff },
          sortBy: [
            SortDescriptor(\.createdAt, order: .forward),
            SortDescriptor(\.id, order: .forward),
          ]
        )
      }
    )
  }

  private func deleteRows<Row: PersistentModel>(
    in context: ModelContext,
    makeDescriptor: @escaping () -> FetchDescriptor<Row>
  ) throws -> Int {
    let batchSize = 256
    var deleted = 0
    while true {
      var descriptor = makeDescriptor()
      descriptor.fetchLimit = batchSize
      let rows = try context.fetch(descriptor)
      guard !rows.isEmpty else {
        return deleted
      }
      rows.forEach(context.delete)
      deleted += rows.count
    }
  }

  private var runInBackgroundEnabled: Bool {
    let storedValue =
      UserDefaults.standard.object(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      ) as? Bool
    return storedValue ?? SupervisorPreferencesDefaults.runInBackgroundDefault
  }

  private var normalizedTolerance: TimeInterval {
    guard interval.isFinite, interval > 0 else {
      return 0
    }
    let requestedTolerance = max(0, tolerance)
    let maxAllowedTolerance = interval > 1 ? interval - 1 : interval / 2
    return min(requestedTolerance, maxAllowedTolerance)
  }
}

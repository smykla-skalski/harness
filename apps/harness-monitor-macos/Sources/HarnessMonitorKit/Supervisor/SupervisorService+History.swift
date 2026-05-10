import Foundation
import SwiftData

extension SupervisorService {
  private static let globalEventHistoryLimit = 64
  private static let perRuleEventHistoryLimit = 256
  private static let decisionHistoryLimit = 128

  func historyWindow(ruleIDs: [String]) async -> PolicyHistoryWindow {
    guard let store else {
      return PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    }
    return await MainActor.run {
      Self.historyWindow(from: store.modelContext, ruleIDs: ruleIDs)
    }
  }

  @MainActor
  static func historyWindow(
    from context: ModelContext?,
    ruleIDs: [String] = []
  ) -> PolicyHistoryWindow {
    // Each tick fetches up to `globalEventHistoryLimit + perRuleEventHistoryLimit *
    // ruleIDs.count` SupervisorEvent rows whose `payloadJSON` strings are several KB
    // each. SwiftData's main `ModelContext` keeps every materialized row in its
    // identity map for the lifetime of the context, so reusing the store's main
    // context here causes the heap to grow ~6 MB per supervisor tick and never
    // shrink. Use an ephemeral child context per call so the materialized rows
    // are released as soon as we have copied the POD summary fields out.
    guard let container = context?.container else {
      return PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    }
    let ephemeralContext = ModelContext(container)

    do {
      let recentEvents = try recentEventSummaries(in: ephemeralContext, ruleIDs: ruleIDs)
      var decisionDescriptor = FetchDescriptor<Decision>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      decisionDescriptor.fetchLimit = Self.decisionHistoryLimit
      let decisions = try ephemeralContext.fetch(decisionDescriptor)
      let recentDecisions: [DecisionSummary] = decisions.compactMap { decision in
        guard let severity = DecisionSeverity(rawValue: decision.severityRaw) else {
          return nil
        }
        return DecisionSummary(
          id: decision.id,
          ruleID: decision.ruleID,
          severity: severity,
          createdAt: decision.createdAt
        )
      }

      return PolicyHistoryWindow(
        recentEvents: recentEvents,
        recentDecisions: recentDecisions
      )
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.history_load_failed error=\(String(describing: error))"
      )
      return PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    }
  }

  @MainActor
  private static func recentEventSummaries(
    in context: ModelContext,
    ruleIDs: [String]
  ) throws -> [SupervisorEventSummary] {
    var summariesByID: [String: SupervisorEventSummary] = [:]
    try mergeEventSummaries(
      from: globalEventDescriptor(),
      into: &summariesByID,
      in: context
    )
    for ruleID in Set(ruleIDs) {
      try mergeEventSummaries(
        from: ruleEventDescriptor(ruleID: ruleID),
        into: &summariesByID,
        in: context
      )
    }
    return summariesByID.values.sorted { left, right in
      if left.createdAt != right.createdAt {
        return left.createdAt > right.createdAt
      }
      return left.id < right.id
    }
  }

  @MainActor
  private static func mergeEventSummaries(
    from descriptor: FetchDescriptor<SupervisorEvent>,
    into summariesByID: inout [String: SupervisorEventSummary],
    in context: ModelContext
  ) throws {
    for event in try context.fetch(descriptor) {
      summariesByID[event.id] = SupervisorEventSummary(
        id: event.id,
        kind: event.kind,
        ruleID: event.ruleID,
        createdAt: event.createdAt,
        actionKey: Self.actionKey(from: event.payloadJSON)
      )
    }
  }

  private static func globalEventDescriptor() -> FetchDescriptor<SupervisorEvent> {
    var descriptor = FetchDescriptor<SupervisorEvent>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = Self.globalEventHistoryLimit
    return descriptor
  }

  private static func ruleEventDescriptor(ruleID: String) -> FetchDescriptor<SupervisorEvent> {
    var descriptor = FetchDescriptor<SupervisorEvent>(
      predicate: #Predicate<SupervisorEvent> { event in
        event.ruleID == ruleID
      },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = Self.perRuleEventHistoryLimit
    return descriptor
  }
}

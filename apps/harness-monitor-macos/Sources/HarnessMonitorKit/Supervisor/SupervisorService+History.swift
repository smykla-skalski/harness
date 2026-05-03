import Foundation
import SwiftData

extension SupervisorService {
  func historyWindow() async -> PolicyHistoryWindow {
    guard let store else {
      return PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    }
    return await MainActor.run {
      Self.historyWindow(from: store.modelContext)
    }
  }

  @MainActor
  static func historyWindow(from context: ModelContext?) -> PolicyHistoryWindow {
    guard let context else {
      return PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    }

    do {
      var eventDescriptor = FetchDescriptor<SupervisorEvent>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      eventDescriptor.fetchLimit = 64
      let recentEvents = try context.fetch(eventDescriptor).map {
        SupervisorEventSummary(
          id: $0.id,
          kind: $0.kind,
          ruleID: $0.ruleID,
          createdAt: $0.createdAt,
          actionKey: Self.actionKey(from: $0.payloadJSON)
        )
      }

      var decisionDescriptor = FetchDescriptor<Decision>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      decisionDescriptor.fetchLimit = 64
      let decisions = try context.fetch(decisionDescriptor)
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
}

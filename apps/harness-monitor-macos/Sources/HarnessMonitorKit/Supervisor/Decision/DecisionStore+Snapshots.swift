import Foundation
import SwiftData

extension DecisionStore {
  nonisolated public func openDecisions() async throws -> [Decision] {
    try await withReadContext { context in
      let descriptor = FetchDescriptor<Decision>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      let rows = try context.fetch(descriptor)
      let now = self.now()
      return rows.filter { self.isOpen($0, now: now) }
    }
  }

  nonisolated public func openDecisionIDs(ruleID: String) async throws -> Set<String> {
    try await withReadContext { context in
      let descriptor = FetchDescriptor<Decision>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      let rows = try context.fetch(descriptor)
      let now = self.now()
      var ids = Set<String>()
      ids.reserveCapacity(rows.count)
      for decision in rows {
        guard decision.ruleID == ruleID, self.isOpen(decision, now: now) else {
          continue
        }
        ids.insert(decision.id)
      }
      return ids
    }
  }

  nonisolated public func openSurfaceSnapshot() async throws -> OpenSurfaceSnapshot {
    try await openSurfaceSnapshot(including: { _ in true })
  }

  nonisolated public func openSupervisorSurfaceSnapshot(
    includeDaemonDisconnect: Bool
  ) async throws -> OpenSurfaceSnapshot {
    try await openSurfaceSnapshot(including: { decision in
      Self.isSupervisorSurfaceDecision(
        decision,
        includeDaemonDisconnect: includeDaemonDisconnect
      )
    })
  }

  nonisolated func openSurfaceSnapshot(
    including includeDecision: @escaping @Sendable (Decision) -> Bool
  ) async throws -> OpenSurfaceSnapshot {
    try await withReadContext { context in
      let descriptor = FetchDescriptor<Decision>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      let rows = try context.fetch(descriptor)
      let now = self.now()
      var decisions: [Decision] = []
      var decisionsByID: [String: Decision] = [:]
      var decisionsBySession: [String: [Decision]] = [:]
      var presentationItems: [DecisionPresentationSnapshot] = []
      var presentationItemsBySession: [String: [DecisionPresentationSnapshot]] = [:]
      var searchProjections: [DecisionSearchProjection] = []
      var searchProjectionsBySession: [String: [DecisionSearchProjection]] = [:]
      var decisionIDsBySession: [String: [String]] = [:]
      var countsBySeverity: [DecisionSeverity: Int] = [:]

      decisions.reserveCapacity(rows.count)
      presentationItems.reserveCapacity(rows.count)
      searchProjections.reserveCapacity(rows.count)

      for decision in rows {
        guard self.isOpen(decision, now: now) else { continue }
        guard includeDecision(decision) else {
          continue
        }

        decisions.append(decision)
        decisionsByID[decision.id] = decision

        let item = DecisionPresentationSnapshot(decision: decision)
        presentationItems.append(item)

        let projection = DecisionSearchProjection(decision: decision)
        searchProjections.append(projection)

        if let sessionID = item.sessionID {
          decisionsBySession[sessionID, default: []].append(decision)
          presentationItemsBySession[sessionID, default: []].append(item)
          searchProjectionsBySession[sessionID, default: []].append(projection)
          decisionIDsBySession[sessionID, default: []].append(item.id)
        }

        if let severity = DecisionSeverity(rawValue: item.severityRaw) {
          countsBySeverity[severity, default: 0] += 1
        }
      }

      return OpenSurfaceSnapshot(
        decisions: decisions,
        decisionsByID: decisionsByID,
        decisionsBySession: decisionsBySession,
        presentationItems: presentationItems,
        presentationItemsBySession: presentationItemsBySession,
        searchProjections: searchProjections,
        searchProjectionsBySession: searchProjectionsBySession,
        decisionIDsBySession: decisionIDsBySession,
        countsBySeverity: countsBySeverity
      )
    }
  }

  nonisolated static func isSupervisorSurfaceDecision(
    _ decision: Decision,
    includeDaemonDisconnect: Bool
  ) -> Bool {
    guard decision.ruleID == DaemonDisconnectRule.ruleID else {
      return true
    }
    guard decision.id == DaemonDisconnectRule.activeDecisionID else {
      return false
    }
    return includeDaemonDisconnect
  }
}

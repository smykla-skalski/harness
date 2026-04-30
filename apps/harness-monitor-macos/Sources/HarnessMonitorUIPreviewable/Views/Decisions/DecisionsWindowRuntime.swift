import HarnessMonitorKit
import SwiftData
import SwiftUI

@MainActor
@Observable
final class DecisionsWindowRuntime {
  var decisions: [Decision] = []
  var auditEvents: [SupervisorEvent] = []
  var liveTick: DecisionLiveTickSnapshot = .placeholder

  func reload(from store: HarnessMonitorStore?) async {
    guard let store else {
      decisions = []
      auditEvents = []
      liveTick = .placeholder
      return
    }

    let decisionStore = await resolveDecisionStore(from: store)
    guard let decisionStore else {
      decisions = []
      auditEvents = []
      liveTick = .placeholder
      return
    }

    decisions = (try? await decisionStore.openDecisions()) ?? []
    auditEvents = Self.loadAuditEvents(from: store.modelContext)
    liveTick = await store.supervisorLiveTickSnapshot()
  }

  private func resolveDecisionStore(from store: HarnessMonitorStore) async -> DecisionStore? {
    if let decisionStore = store.supervisorDecisionStore {
      return decisionStore
    }

    await store.startSupervisor()
    return store.supervisorDecisionStore
  }

  private static func loadAuditEvents(from modelContext: ModelContext?) -> [SupervisorEvent] {
    guard let modelContext else {
      return []
    }

    do {
      var descriptor = FetchDescriptor<SupervisorEvent>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      descriptor.fetchLimit = 128
      return try modelContext.fetch(descriptor)
    } catch {
      return []
    }
  }
}

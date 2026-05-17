import HarnessMonitorKit
import SwiftUI

@MainActor
@Observable
final class DecisionRuntime {
  var decisions: [Decision] = []
  var auditEvents: [SupervisorEventSnapshot] = []
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
    auditEvents = await store.loadSupervisorAuditEventSnapshots()
    await refreshLiveTick(from: store)
  }

  func refreshLiveTick(from store: HarnessMonitorStore?) async {
    guard let store else {
      liveTick = .placeholder
      return
    }
    liveTick = await store.supervisorLiveTickSnapshot()
  }

  private func resolveDecisionStore(from store: HarnessMonitorStore) async -> DecisionStore? {
    if let decisionStore = store.supervisorDecisionStore {
      return decisionStore
    }

    await store.startSupervisor()
    return store.supervisorDecisionStore
  }
}

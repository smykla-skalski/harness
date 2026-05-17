import HarnessMonitorKit
import SwiftUI

@MainActor
@Observable
final class DecisionRuntime {
  var decisions: [Decision] = []
  var decisionsByID: [String: Decision] = [:]
  var decisionItems: [DecisionPresentationItem] = []
  var decisionsRevision: UInt64 = 0
  var auditEvents: [SupervisorEventSnapshot] = []
  var liveTick: DecisionLiveTickSnapshot = .placeholder

  func reload(from store: HarnessMonitorStore?) async {
    guard let store else {
      applyDecisions([])
      auditEvents = []
      liveTick = .placeholder
      return
    }

    let decisionStore = await resolveDecisionStore(from: store)
    guard let decisionStore else {
      applyDecisions([])
      auditEvents = []
      liveTick = .placeholder
      return
    }

    applyDecisions((try? await decisionStore.openDecisions()) ?? [])
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

  private func applyDecisions(_ nextDecisions: [Decision]) {
    decisions = nextDecisions
    decisionsByID = Dictionary(uniqueKeysWithValues: nextDecisions.map { ($0.id, $0) })
    decisionItems = nextDecisions.map(DecisionPresentationItem.init)
    decisionsRevision &+= 1
  }
}

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
      applyDecisionSurfaceSnapshot(.empty)
      auditEvents = []
      liveTick = .placeholder
      return
    }

    let decisionStore = await resolveDecisionStore(from: store)
    guard let decisionStore else {
      applyDecisionSurfaceSnapshot(.empty)
      auditEvents = []
      liveTick = .placeholder
      return
    }

    applyDecisionSurfaceSnapshot((try? await decisionStore.openSurfaceSnapshot()) ?? .empty)
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

  private func applyDecisionSurfaceSnapshot(_ snapshot: DecisionStore.OpenSurfaceSnapshot) {
    decisions = snapshot.decisions
    decisionsByID = snapshot.decisionsByID
    decisionItems = snapshot.presentationItems
    decisionsRevision &+= 1
  }
}

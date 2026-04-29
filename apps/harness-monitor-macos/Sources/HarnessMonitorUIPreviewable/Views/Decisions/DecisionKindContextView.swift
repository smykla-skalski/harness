import HarnessMonitorKit
import SwiftUI

@MainActor
struct DecisionKindContextView: View {
  let adapter: DecisionKindContextAdapter
  let contextSections: [DecisionDetailViewModel.ContextSection]

  var body: some View {
    switch adapter.kind {
    case .generic:
      DecisionContextPanel(sections: contextSections)
    case .acpPermission(let payload):
      AcpPermissionDecisionDetailView(payload: payload, store: adapter.store)
    }
  }
}

@MainActor
struct DecisionKindContextAdapter {
  enum Kind {
    case generic
    case acpPermission(AcpPermissionDecisionPayload)
  }

  let kind: Kind
  let store: HarnessMonitorStore?

  init(decision: Decision, store: HarnessMonitorStore?) {
    self.store = store
    kind = Self.resolveKind(decision: decision, store: store)
  }

  func isActionDisabled(_ actionID: String) -> Bool {
    guard case .acpPermission(let payload) = kind else {
      return false
    }

    let resolutionState =
      store?.acpPermissionResolutionState(for: payload.decisionID)
      ?? payload.defaultResolutionState
    if resolutionState.isSubmitting
      || store?.resolvingAcpPermissionBatchID == payload.rawBatch.batchId
    {
      return true
    }
    return payload.isActionDisabled(actionID, resolutionState: resolutionState)
  }

  private static func resolveKind(
    decision: Decision,
    store: HarnessMonitorStore?
  ) -> Kind {
    guard decision.ruleID == AcpPermissionDecisionPayload.ruleID else {
      return .generic
    }
    guard
      let payload = store?.acpPermissionDecisionPayload(for: decision.id)
        ?? AcpPermissionDecisionPayload.decode(from: decision)
    else {
      return .generic
    }
    return .acpPermission(payload)
  }
}

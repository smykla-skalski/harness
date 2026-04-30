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

  func suggestedActions(from actions: [SuggestedAction]) -> [SuggestedAction] {
    guard case .acpPermission(let payload) = kind else {
      return actions
    }
    return payload.suggestedActions()
  }

  private static func resolveKind(
    decision: Decision,
    store: HarnessMonitorStore?
  ) -> Kind {
    guard decision.ruleID == AcpPermissionDecisionPayload.ruleID else {
      return .generic
    }
    // ACP decisions stay on the ACP-specific detail path even when persisted context can only
    // decode into a render-error fallback. That keeps the UI contract stable at the routing seam.
    guard
      let payload = store?.acpPermissionDecisionPayload(for: decision.id)
        ?? AcpPermissionDecisionPayload.decode(from: decision)
    else {
      assertionFailure("ACP decisions must decode into a renderable or fallback payload")
      return .generic
    }
    return .acpPermission(payload)
  }
}

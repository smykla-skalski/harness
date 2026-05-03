import HarnessMonitorKit
import SwiftUI

extension View {
  func acpPermissionPresentation(store: HarnessMonitorStore) -> some View {
    modifier(AcpPermissionPresentationModifier(store: store))
  }
}

private struct AcpPermissionPresentationModifier: ViewModifier {
  let store: HarnessMonitorStore
  @Environment(\.openWindow)
  private var openWindow

  func body(content: Content) -> some View {
    content
      .task(id: store.presentingAcpPermissionBatch?.batchId) {
        routeToDecisionsIfNeeded()
      }
      .onChange(of: store.presentingAcpPermissionBatch?.batchId) { _, _ in
        routeToDecisionsIfNeeded()
      }
  }

  private func routeToDecisionsIfNeeded() {
    guard let batch = store.presentingAcpPermissionBatch else {
      return
    }
    let payload = store.acpPermissionDecisionPayload(for: batch)
    store.presentingAcpPermissionBatch = nil
    guard payload.isRenderable else {
      store.supervisorSelectedDecisionID = nil
      return
    }
    store.requestWorkspaceDecisionSelection(decisionID: payload.decisionID)
    store.supervisorSelectedDecisionID = payload.decisionID
    store.requestPrimaryDecisionActionFocus(decisionID: payload.decisionID)
    openWindow(id: HarnessMonitorWindowID.workspace)
  }
}

import HarnessMonitorKit
import SwiftUI

extension View {
  func acpPermissionPresentation(store: HarnessMonitorStore) -> some View {
    modifier(AcpPermissionPresentationModifier(store: store))
  }
}

private struct AcpPermissionPresentationModifier: ViewModifier {
  let store: HarnessMonitorStore

  func body(content: Content) -> some View {
    content.sheet(item: acpPermissionBatchBinding) { batch in
      AcpPermissionModal(
        batch: batch,
        isResolving: store.resolvingAcpPermissionBatchID == batch.batchId
      ) { decision in
        Task {
          await store.resolveAcpPermission(batch: batch, decision: decision)
        }
      }
    }
  }

  private var acpPermissionBatchBinding: Binding<AcpPermissionBatch?> {
    Binding {
      store.presentingAcpPermissionBatch
    } set: { batch in
      store.presentingAcpPermissionBatch = batch
    }
  }
}

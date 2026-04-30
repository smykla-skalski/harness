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
    content.popover(
      item: acpPermissionBatchBinding,
      attachmentAnchor: .rect(.bounds),
      arrowEdge: .top
    ) { batch in
      AcpPermissionModal(store: store, batch: batch)
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

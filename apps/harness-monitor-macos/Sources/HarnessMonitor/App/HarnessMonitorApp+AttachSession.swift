import HarnessMonitorKit
import SwiftUI

extension View {
  /// Presents the Attach External Session file importer, bound to the store's
  /// `attachSessionRequest` counter.
  func attachExternalSessionImporter(store: HarnessMonitorStore) -> some View {
    modifier(AttachExternalSessionImporter(store: store))
  }
}

private struct AttachExternalSessionImporter: ViewModifier {
  let store: HarnessMonitorStore
  @State private var showImporter = false

  func body(content: Content) -> some View {
    content
      .fileImporter(
        isPresented: $showImporter,
        allowedContentTypes: [.folder],
        allowsMultipleSelection: false
      ) { result in
        Task { await store.handleAttachSessionPicker(result) }
      }
      .onChange(of: store.attachSessionRequest) { _, _ in
        showImporter = true
      }
  }
}

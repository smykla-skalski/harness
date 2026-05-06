import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

#Preview("New Session Sheet") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(
    for: .dashboardLoaded,
    modelContainer: HarnessMonitorPreviewStoreFactory.previewContainer
  )
  let viewModel = NewSessionViewModel(
    store: store,
    bookmarkStore: BookmarkStore(
      containerURL: FileManager.default.temporaryDirectory
    ),
    client: PreviewHarnessClient(fixtures: .populated, isLaunchAgentInstalled: true)
  )
  NewSessionSheetView(store: store, viewModel: viewModel)
    .frame(width: 520)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
}

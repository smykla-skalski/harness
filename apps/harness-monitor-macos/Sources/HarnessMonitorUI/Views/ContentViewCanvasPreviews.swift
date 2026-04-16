import HarnessMonitorKit
import SwiftUI

#Preview("Canvas - Toolbar + Top Chrome") {
  ContentViewCanvasPreview(scenario: .cockpitLoaded)
    .frame(width: 1100, height: 320)
}

#Preview("Canvas - Dashboard Landing") {
  ContentViewCanvasPreview(scenario: .dashboardLanding)
    .frame(width: 1100, height: 320)
}

#Preview("Canvas - Sidebar Overflow") {
  ContentViewCanvasPreview(scenario: .sidebarOverflow)
    .frame(width: 1100, height: 320)
}

private struct ContentViewCanvasPreview: View {
  let scenario: HarnessMonitorPreviewStoreFactory.Scenario
  @State private var store: HarnessMonitorStore?

  var body: some View {
    Group {
      if let store {
        ContentView(store: store)
      } else {
        ProgressView("Loading preview...")
      }
    }
    .task {
      store = HarnessMonitorPreviewStoreFactory.makeStore(
        for: scenario,
        modelContainer: HarnessMonitorPreviewStoreFactory.previewContainer
      )
    }
  }
}

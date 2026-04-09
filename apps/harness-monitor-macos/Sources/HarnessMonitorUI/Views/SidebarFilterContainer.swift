import HarnessMonitorKit
import SwiftUI

// The sidebar now uses toolbar-native search and filtering surfaces.
// This legacy container remains as an inert placeholder until it is removed
// from the project in a follow-up cleanup.
struct SidebarFilterContainer: View {
  let store: HarnessMonitorStore
  let sessionIndex: HarnessMonitorStore.SessionIndexSlice

  var body: some View {
    EmptyView()
  }
}

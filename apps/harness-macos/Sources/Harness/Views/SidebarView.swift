import HarnessKit
import Observation
import SwiftUI

struct SidebarView: View {
  @Bindable var store: HarnessStore
  let themeStyle: HarnessThemeStyle

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(alignment: .leading, spacing: 18) {
        DaemonStatusCard(store: store)
        SidebarSessionList(store: store)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(22)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(HarnessTheme.ink)
    .contentShape(Rectangle())
    .accessibilityFrameMarker(HarnessAccessibility.sidebarShellFrame)
    .animation(.snappy(duration: 0.24), value: store.groupedSessions)
    .animation(.snappy(duration: 0.24), value: store.isRefreshing)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.sidebarRoot)
  }
}

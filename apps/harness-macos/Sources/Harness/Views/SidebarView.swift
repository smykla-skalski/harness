import HarnessKit
import Observation
import SwiftUI

struct SidebarView: View {
  let store: HarnessStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        DaemonStatusCard(store: store)
        SidebarSessionList(store: store)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.vertical, 22)
      .padding(.horizontal, 14)
    }
    .scrollIndicators(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(HarnessTheme.ink)
    .contentShape(Rectangle())
    .accessibilityFrameMarker(HarnessAccessibility.sidebarShellFrame)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.sidebarRoot)
  }
}

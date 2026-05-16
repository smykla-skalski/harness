import HarnessMonitorKit
import SwiftUI

struct DashboardWindowToolbar: ToolbarContent {
  let store: HarnessMonitorStore
  let showsQuickActions: Bool
  let sleepPreventionPresentation: SleepPreventionToolbarPresentation

  @ToolbarContentBuilder var body: some ToolbarContent {
    HarnessMonitorWindowToolbar {
      ToolbarItemGroup(placement: .navigation) {
        if showsQuickActions {
          Button {
            store.presentedSheet = .newSession
          } label: {
            Label {
              Text("New Session")
            } icon: {
              Image(systemName: "plus.square")
                .frame(width: 14, height: 14)
            }
          }
          .help("New Session")
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardNewSessionButton)
          .harnessMCPButton(
            HarnessMonitorAccessibility.dashboardNewSessionButton,
            label: "New Session",
            hint: "Create a new session.",
            pressAction: { store.presentedSheet = .newSession }
          )

          Button {
            store.requestOpenFolder()
          } label: {
            Label {
              Text("Open Folder")
            } icon: {
              Image(systemName: "folder")
                .frame(width: 14, height: 14)
            }
          }
          .help("Open Folder")
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardOpenFolderButton)
          .harnessMCPButton(
            HarnessMonitorAccessibility.dashboardOpenFolderButton,
            label: "Open Folder",
            hint: "Open a project folder.",
            pressAction: { store.requestOpenFolder() }
          )
        }
      }
    } automatic: {
      ToolbarItemGroup(placement: .automatic) {}
    } primaryAction: {
      ToolbarItem(placement: .primaryAction) {
        SleepPreventionToolbarButton(
          store: store,
          presentation: sleepPreventionPresentation
        )
      }
    }
  }
}

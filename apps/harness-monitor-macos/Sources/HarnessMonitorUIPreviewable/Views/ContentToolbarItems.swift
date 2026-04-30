import HarnessMonitorKit
import SwiftUI

struct ContentWindowToolbarModel: Equatable {
  let canNavigateBack: Bool
  let canNavigateForward: Bool
  let canStartNewSession: Bool
  let isRefreshing: Bool
  let sleepPreventionEnabled: Bool

  var sleepPreventionTitle: String {
    sleepPreventionEnabled ? "Sleep Prevention On" : "Prevent Sleep"
  }

  var sleepPreventionSystemImage: String {
    sleepPreventionEnabled ? "moon.zzz.fill" : "moon.zzz"
  }
}

struct ContentWindowToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let model: ContentWindowToolbarModel

  init(store: HarnessMonitorStore, model: ContentWindowToolbarModel) {
    self.store = store
    self.model = model
  }

  @ToolbarContentBuilder var body: some ToolbarContent {
    ContentNavigationToolbar(store: store, model: model)
    SidebarToolbarNewSessionToolbarItem(
      isEnabled: model.canStartNewSession,
      presentNewSession: { store.presentedSheet = .newSession }
    )
  }
}

struct ContentPrimaryToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let model: ContentWindowToolbarModel

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        store.sleepPreventionEnabled.toggle()
      } label: {
        Label(
          model.sleepPreventionTitle,
          systemImage: model.sleepPreventionSystemImage
        )
      }
      .tint(model.sleepPreventionEnabled ? .orange : nil)
      .help(
        model.sleepPreventionEnabled
          ? "Click to allow system sleep"
          : "Prevent sleep while sessions are active"
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)
      RefreshToolbarButton(isRefreshing: model.isRefreshing) {
        Task { await store.refresh() }
      }
      .help("Refresh sessions")
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
      AgentsToolbarButton()
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
      SupervisorToolbarItem(slice: store.supervisorToolbarSlice)
    }
  }
}

private struct AgentsToolbarButton: View {
  @Environment(\.openWindow)
  private var openWindow

  var body: some View {
    Button {
      openWindow(id: HarnessMonitorWindowID.agents)
    } label: {
      Label {
        Text("Agents")
      } icon: {
        Image("ProviderSymbol-copilot")
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .frame(width: 14, height: 14)
          .accessibilityHidden(true)
      }
    }
    .help("Open Agents window")
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentsActionButton)
  }
}

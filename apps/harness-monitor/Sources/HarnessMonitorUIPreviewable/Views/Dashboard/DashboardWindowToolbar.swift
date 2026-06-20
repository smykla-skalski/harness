import HarnessMonitorKit
import SwiftUI

struct DashboardWindowToolbar: ToolbarContent {
  let store: HarnessMonitorStore
  let navigation: WindowNavigationState
  let showsQuickActions: Bool
  let showsPolicyInspectorToggle: Bool
  let sleepPreventionPresentation: SleepPreventionToolbarPresentation

  @ToolbarContentBuilder var body: some ToolbarContent {
    WindowHistoryToolbarItems(
      navigation: navigation,
      backAccessibilityIdentifier: HarnessMonitorAccessibility.navigateBackButton,
      forwardAccessibilityIdentifier: HarnessMonitorAccessibility.navigateForwardButton,
      shortcutOverlay: nil
    )

    if showsQuickActions {
      ToolbarItem(placement: .primaryAction) {
        newSessionButton
      }
      ToolbarSpacer(.fixed, placement: .primaryAction)
      ToolbarItem(placement: .primaryAction) {
        openFolderButton
      }
      ToolbarSpacer(.fixed, placement: .primaryAction)
    }

    if showsPolicyInspectorToggle {
      ToolbarItem(placement: .primaryAction) {
        PolicyCanvasInspectorToolbarButton()
      }
      ToolbarSpacer(.fixed, placement: .primaryAction)
    }

    ToolbarItemGroup(placement: .primaryAction) {
      SleepPreventionToolbarButton(
        store: store,
        presentation: sleepPreventionPresentation
      )
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
      .sharedBackgroundVisibility(.hidden)

    GlobalPolicyEnforcementToolbarGroup(store: store)
  }
}

private struct PolicyCanvasInspectorToolbarButton: View {
  @FocusedValue(\.harnessPolicyCanvasCommandFocus)
  private var policyCanvasCommandFocus

  private var policyCanvasInspectorFocus: PolicyCanvasInspectorFocus? {
    policyCanvasCommandFocus?.inspector
  }

  private var policyCanvasInspectorButtonTitle: String {
    policyCanvasInspectorFocus?.isVisible == true
      ? "Hide Policy Inspector"
      : "Show Policy Inspector"
  }

  private var isToggleEnabled: Bool {
    policyCanvasInspectorFocus?.canToggle == true
  }

  var body: some View {
    Button {
      policyCanvasInspectorFocus?.dispatcher.performToggleInspector()
    } label: {
      Label {
        Text(policyCanvasInspectorButtonTitle)
      } icon: {
        Image(systemName: "sidebar.trailing")
          .frame(width: 14, height: 14)
      }
    }
    .disabled(!isToggleEnabled)
    .help(policyCanvasInspectorButtonTitle)
    .accessibilityLabel("Policy Inspector")
    .accessibilityValue(policyCanvasInspectorFocus?.isVisible == true ? "Shown" : "Hidden")
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasInspectorToolbarButton)
    .harnessMCPButton(
      HarnessMonitorAccessibility.policyCanvasInspectorToolbarButton,
      label: "Policy Inspector",
      value: policyCanvasInspectorFocus?.isVisible == true ? "Shown" : "Hidden",
      hint: policyCanvasInspectorButtonTitle,
      pressAction: {
        policyCanvasInspectorFocus?.dispatcher.performToggleInspector()
      }
    )
  }
}

extension DashboardWindowToolbar {
  private var newSessionButton: some View {
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
      hint: "Create a new session",
      pressAction: { store.presentedSheet = .newSession }
    )
  }

  private var openFolderButton: some View {
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
      hint: "Open a project folder",
      pressAction: { store.requestOpenFolder() }
    )
  }
}

import HarnessMonitorKit
import HarnessMonitorPolicyCanvas
import SwiftUI

struct DashboardWindowToolbar: ToolbarContent {
  let store: HarnessMonitorStore
  let navigation: WindowNavigationState
  let showsQuickActions: Bool
  let inspector: DashboardInspectorToolbarPresentation?
  let sleepPreventionPresentation: SleepPreventionToolbarPresentation

  @ToolbarContentBuilder var body: some ToolbarContent {
    WindowHistoryToolbarItems(
      navigation: navigation,
      backAccessibilityIdentifier: HarnessMonitorAccessibility.navigateBackButton,
      forwardAccessibilityIdentifier: HarnessMonitorAccessibility.navigateForwardButton,
      shortcutOverlay: nil
    )

    if showsQuickActions {
      ToolbarItem(id: "dashboard.new-session", placement: .primaryAction) {
        newSessionButton
      }
      ToolbarSpacer(.fixed, placement: .primaryAction)
      ToolbarItem(id: "dashboard.open-folder", placement: .primaryAction) {
        openFolderButton
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

    if let inspector {
      ToolbarSpacer(.fixed, placement: .primaryAction)
        .sharedBackgroundVisibility(.hidden)
      ToolbarItem(id: "dashboard.inspector", placement: .primaryAction) {
        DashboardInspectorToolbarButton(presentation: inspector)
      }
    }
  }
}

enum DashboardInspectorToolbarPresentation: Equatable {
  case taskBoard
  case policyCanvas
}

extension DashboardWindowRoute {
  var inspectorToolbarPresentation: DashboardInspectorToolbarPresentation? {
    switch self {
    case .taskBoard:
      .taskBoard
    case .policyCanvas:
      .policyCanvas
    default:
      nil
    }
  }
}

private struct DashboardInspectorToolbarButton: View {
  let presentation: DashboardInspectorToolbarPresentation

  @ViewBuilder var body: some View {
    switch presentation {
    case .taskBoard:
      TaskBoardOperationsInspectorToolbarButton()
    case .policyCanvas:
      PolicyCanvasInspectorToolbarButton()
    }
  }
}

private struct TaskBoardOperationsInspectorToolbarButton: View {
  @FocusedValue(\.harnessTaskBoardCommandFocus)
  private var taskBoardCommandFocus

  private var operationsInspectorFocus: TaskBoardOperationsInspectorFocus? {
    taskBoardCommandFocus?.operationsInspector
  }

  private var buttonTitle: String {
    operationsInspectorFocus?.isVisible == true
      ? "Hide Task Board Operations"
      : "Show Task Board Operations"
  }

  private var isToggleEnabled: Bool {
    operationsInspectorFocus?.canToggle == true
  }

  var body: some View {
    Button {
      guard isToggleEnabled else { return }
      operationsInspectorFocus?.dispatcher.performToggleInspector()
    } label: {
      Image(systemName: "sidebar.trailing")
        .frame(width: 14, height: 14)
    }
    .disabled(!isToggleEnabled)
    .help(buttonTitle)
    .accessibilityLabel("Task Board Operations")
    .accessibilityValue(operationsInspectorFocus?.isVisible == true ? "Shown" : "Hidden")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.taskBoardOperationsInspectorButton
    )
    .harnessMCPButton(
      HarnessMonitorAccessibility.taskBoardOperationsInspectorButton,
      label: "Task Board Operations",
      value: operationsInspectorFocus?.isVisible == true ? "Shown" : "Hidden",
      hint: buttonTitle,
      enabled: isToggleEnabled,
      pressAction: {
        guard isToggleEnabled else { return }
        operationsInspectorFocus?.dispatcher.performToggleInspector()
      }
    )
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
      Image(systemName: "sidebar.trailing")
        .frame(width: 14, height: 14)
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

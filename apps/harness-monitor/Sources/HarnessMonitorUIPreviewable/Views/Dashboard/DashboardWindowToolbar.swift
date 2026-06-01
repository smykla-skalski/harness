import HarnessMonitorKit
import SwiftUI

struct DashboardWindowToolbar: ToolbarContent {
  let store: HarnessMonitorStore
  let navigation: WindowNavigationState
  let showsQuickActions: Bool
  let showsPolicyKillSwitch: Bool
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

    if showsPolicyKillSwitch {
      ToolbarSpacer(.fixed, placement: .primaryAction)
      ToolbarItem(placement: .primaryAction) {
        policyKillSwitchButton
      }
      ToolbarSpacer(.fixed, placement: .primaryAction)
    }

    ToolbarItem(placement: .primaryAction) {
      SleepPreventionToolbarButton(
        store: store,
        presentation: sleepPreventionPresentation
      )
    }
  }
}

extension DashboardWindowToolbar {
  private var policyWorkspace: TaskBoardPolicyCanvasWorkspace? {
    store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace
  }

  private var policyEnforcementKillSwitchActive: Bool {
    policyWorkspace?.policyEnforcementKillSwitchActive ?? false
  }

  private var policyEnforcementToggleAvailable: Bool {
    if policyEnforcementKillSwitchActive {
      return true
    }
    return policyWorkspace?.canvases.contains { $0.mode != .draft } ?? false
  }

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

  private var policyKillSwitchButton: some View {
    Button {
      togglePolicyEnforcement()
    } label: {
      Label(
        policyEnforcementKillSwitchActive ? "Restore Policies" : "Disable Policies",
        systemImage: policyEnforcementKillSwitchActive ? "checkmark.shield" : "xmark.shield"
      )
    }
    .disabled(store.isDaemonActionInFlight || !policyEnforcementToggleAvailable)
    .help(policyKillSwitchHelpText)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasPolicyKillSwitchButton)
    .harnessMCPButton(
      HarnessMonitorAccessibility.policyCanvasPolicyKillSwitchButton,
      label: policyEnforcementKillSwitchActive ? "Restore Policies" : "Disable Policies",
      hint: policyKillSwitchHelpText,
      pressAction: togglePolicyEnforcement
    )
  }

  private var policyKillSwitchHelpText: String {
    if policyEnforcementKillSwitchActive {
      return "Restore policy enforcement to the previous canvas state"
    }
    if !policyEnforcementToggleAvailable {
      return "No enforced policies to disable"
    }
    return "Disable policy enforcement for all policy canvases"
  }

  @MainActor
  private func togglePolicyEnforcement() {
    guard policyEnforcementToggleAvailable, !store.isDaemonActionInFlight else {
      return
    }
    Task { @MainActor in
      guard await store.toggleTaskBoardPolicyCanvasEnforcement() else {
        return
      }
      syncCanvasAutomationPolicies()
    }
  }

  @MainActor
  private func syncCanvasAutomationPolicies() {
    guard let activeDocument = store.contentUI.dashboard.taskBoardPolicyPipeline else {
      return
    }
    let policyCenter = AutomationPolicyCenter.shared
    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace,
      activeDocument: activeDocument
    )
    guard !compilation.policies.isEmpty || policyCenter.document.hasCanvasPolicies else {
      return
    }
    policyCenter.replaceCanvasPolicies(compilation.policies)
  }
}

import HarnessMonitorKit
import HarnessMonitorPolicyCanvas
import SwiftUI

public struct GlobalPolicyEnforcementToolbarGroup: ToolbarContent {
  private let store: HarnessMonitorStore

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  public var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      globalEnforcementButton
    }
  }

  private var policyWorkspace: PolicyCanvasWorkspace? {
    store.contentUI.dashboard.policyCanvasWorkspace
  }

  private var globalPolicyEnforcementEnabled: Bool {
    policyWorkspace?.globalPolicyEnforcementEnabled ?? true
  }

  private var globalEnforcementButtonDisabled: Bool {
    store.connectionState != .online
  }

  private var globalEnforcementActionBlocked: Bool {
    globalEnforcementButtonDisabled || store.isDaemonActionInFlight
  }

  private var globalEnforcementButton: some View {
    // Keep this plain so AppKit supplies the native toolbar platter.
    Button {
      setGlobalPolicyEnforcementEnabled(!globalPolicyEnforcementEnabled)
    } label: {
      Label {
        Text(
          globalPolicyEnforcementEnabled
            ? "Disable Global Enforcement"
            : "Enable Global Enforcement"
        )
      } icon: {
        Image(systemName: globalPolicyEnforcementEnabled ? "checkmark.shield" : "xmark.shield")
          .contentTransition(.symbolEffect(.replace))
      }
    }
    .disabled(globalEnforcementButtonDisabled)
    .foregroundStyle(globalPolicyEnforcementEnabled ? Color.green : Color.red)
    .animation(.snappy(duration: 0.18), value: globalPolicyEnforcementEnabled)
    .help(globalEnforcementHelpText)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasGlobalEnforcementButton)
    .harnessMCPButton(
      HarnessMonitorAccessibility.policyCanvasGlobalEnforcementButton,
      label: globalPolicyEnforcementEnabled
        ? "Disable Global Enforcement"
        : "Enable Global Enforcement",
      hint: globalEnforcementHelpText,
      pressAction: {
        setGlobalPolicyEnforcementEnabled(!globalPolicyEnforcementEnabled)
      }
    )
  }

  private var globalEnforcementHelpText: String {
    guard store.connectionState == .online else {
      return "Global policy enforcement requires a connected daemon"
    }
    if globalPolicyEnforcementEnabled {
      return "Global policy enforcement is enabled"
    }
    return "Global policy enforcement is disabled"
  }

  @MainActor
  private func setGlobalPolicyEnforcementEnabled(_ enabled: Bool) {
    guard !globalEnforcementActionBlocked else {
      return
    }
    Task { @MainActor in
      guard await store.setPolicyCanvasGlobalEnforcement(enabled: enabled) else {
        return
      }
      syncCanvasAutomationPolicies()
    }
  }

  @MainActor
  private func syncCanvasAutomationPolicies() {
    let policyCenter = AutomationPolicyCenter.shared
    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: store.contentUI.dashboard.policyCanvasWorkspace,
      activeDocument: store.contentUI.dashboard.policyPipeline
    )
    let compiledPolicies = compilation.policies.map(AutomationPolicy.init)
    guard !compiledPolicies.isEmpty || policyCenter.document.hasCanvasPolicies else {
      return
    }
    policyCenter.replaceCanvasPolicies(compiledPolicies)
  }
}

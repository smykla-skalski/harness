import HarnessMonitorKit
import SwiftUI

public struct AutomationKillSwitchToolbarGroup: ToolbarContent {
  private let store: HarnessMonitorStore

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  public var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      AutomationKillSwitchButton(store: store)
    }
  }
}

struct AutomationKillSwitchButton: View {
  let store: HarnessMonitorStore

  private var automationKillSwitchEngaged: Bool {
    store.contentUI.dashboard.policyCanvasWorkspace?.spawnKillSwitch ?? false
  }

  var body: some View {
    Button {
      setAutomationKillSwitch(enabled: !automationKillSwitchEngaged)
    } label: {
      Image(systemName: automationKillSwitchIcon)
        .frame(width: 14, height: 14)
        .contentTransition(.symbolEffect(.replace))
    }
    .disabled(store.connectionState != .online)
    .foregroundStyle(automationKillSwitchEngaged ? HarnessMonitorTheme.danger : Color.primary)
    .animation(.snappy(duration: 0.18), value: automationKillSwitchEngaged)
    .help(automationKillSwitchHelpText)
    .accessibilityLabel("App Kill Switch")
    .accessibilityIdentifier(HarnessMonitorAccessibility.automationKillSwitchButton)
    .accessibilityValue(automationKillSwitchStateText)
    .harnessMCPButton(
      HarnessMonitorAccessibility.automationKillSwitchButton,
      label: "App Kill Switch",
      value: automationKillSwitchStateText,
      hint: automationKillSwitchHelpText,
      pressAction: {
        setAutomationKillSwitch(enabled: !automationKillSwitchEngaged)
      }
    )
  }

  private var automationKillSwitchIcon: String {
    automationKillSwitchEngaged ? "shield.slash.fill" : "shield.fill"
  }

  private var automationKillSwitchStateText: String {
    automationKillSwitchEngaged ? "Engaged" : "Off"
  }

  private var automationKillSwitchHelpText: String {
    guard store.connectionState == .online else {
      return "App kill switch requires a connected daemon"
    }
    return automationKillSwitchEngaged
      ? "Disengage App Kill Switch"
      : "Engage App Kill Switch"
  }

  @MainActor
  private func setAutomationKillSwitch(enabled: Bool) {
    guard store.connectionState == .online else {
      return
    }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: enabled ? "Engaging app kill switch" : "Disengaging app kill switch") {
        guard await store.setPolicyCanvasSpawnKillSwitch(enabled: enabled) else {
          return
        }
        await MainActor.run {
          AutomationPolicyCenter.shared.setKillSwitchEngaged(enabled)
        }
      }
    )
  }
}

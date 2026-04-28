import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  var agentTuiUnavailableBanner: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(agentTuiBridgeTitle, systemImage: "exclamationmark.triangle")
        .scaledFont(.headline)
        .foregroundStyle(.orange)
      Text(agentTuiBridgeMessage)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if agentTuiBridgeState == .excluded && hostBridge.running {
        Button("Enable now") {
          Task {
            _ = await store.setHostBridgeCapability("agent-tui", enabled: true)
          }
        }
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(store.isDaemonActionInFlight || viewModel.isSubmitting)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiEnableBridgeButton)
      }
      CopyableCommandBox(
        command: agentTuiBridgeCommand,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiCopyCommandButton
      )
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRecoveryBanner)
  }

  var agentTuiBridgeState: HarnessMonitorStore.HostBridgeCapabilityState {
    store.hostBridgeCapabilityState(for: "agent-tui")
  }

  var agentTuiBridgeCommand: String {
    store.hostBridgeStartCommand(for: "agent-tui")
  }

  var hostBridge: HostBridgeManifest {
    store.daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
  }

  var agentTuiBridgeCapabilityPresent: Bool {
    hostBridge.capabilities["agent-tui"] != nil
  }

  var agentTuiBridgeTitle: String {
    switch agentTuiBridgeState {
    case .excluded:
      "Terminal agents are excluded from the host bridge"
    case .unavailable:
      "Terminal agent host bridge is not running"
    case .ready:
      "Terminal agent host bridge ready"
    }
  }

  var agentTuiBridgeMessage: String {
    switch agentTuiBridgeState {
    case .excluded:
      "The shared host bridge is running without terminal control enabled. "
        + "Enable it now or run this in a terminal:"
    case .unavailable:
      if hostBridge.running && agentTuiBridgeCapabilityPresent {
        "The shared host bridge is running, but terminal control is unavailable. "
          + "Re-enable it or run this in a terminal:"
      } else {
        "Harness Monitor runs sandboxed and needs the host bridge to start "
          + "or steer terminal-backed agents. Run this in a terminal:"
      }
    case .ready:
      ""
    }
  }

  var codexUnavailableBanner: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(codexBridgeTitle, systemImage: "exclamationmark.triangle")
        .scaledFont(.headline)
        .foregroundStyle(.orange)
      Text(codexBridgeMessage)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if codexBridgeState == .excluded && hostBridge.running {
        Button("Enable now") {
          Task {
            _ = await store.setHostBridgeCapability("codex", enabled: true)
          }
        }
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(store.isDaemonActionInFlight || viewModel.isSubmitting)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCodexEnableBridgeButton)
      }
      CopyableCommandBox(
        command: codexBridgeCommand,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentsCodexCopyCommandButton
      )
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCodexRecoveryBanner)
  }

  var codexBridgeState: HarnessMonitorStore.HostBridgeCapabilityState {
    store.hostBridgeCapabilityState(for: "codex")
  }

  var codexBridgeCommand: String {
    store.hostBridgeStartCommand(for: "codex")
  }

  var codexBridgeCapabilityPresent: Bool {
    hostBridge.capabilities["codex"] != nil
  }

  var codexBridgeTitle: String {
    switch codexBridgeState {
    case .excluded:
      "Codex is excluded from the host bridge"
    case .unavailable:
      if hostBridge.running && codexBridgeCapabilityPresent {
        "Codex host bridge is unavailable"
      } else {
        "Codex host bridge is not running"
      }
    case .ready:
      "Codex host bridge ready"
    }
  }

  var codexBridgeMessage: String {
    switch codexBridgeState {
    case .excluded:
      "The shared host bridge is running without Codex enabled. Enable it now or run this in a terminal:"
    case .unavailable:
      if hostBridge.running && codexBridgeCapabilityPresent {
        """
        The shared host bridge is running, but the Codex capability is unavailable.
        Re-enable it or run this in a terminal:
        """
      } else {
        """
        Harness Monitor runs sandboxed and needs the host bridge to start or steer
        Codex threads. Run this in a terminal:
        """
      }
    case .ready:
      ""
    }
  }
}

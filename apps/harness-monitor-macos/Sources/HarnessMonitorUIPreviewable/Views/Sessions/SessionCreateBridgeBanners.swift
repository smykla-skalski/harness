import HarnessMonitorKit
import SwiftUI

struct SessionCreateBridgeBannerCopy {
  let title: String
  let message: String
  let command: String
  let enableLabel: String?
  let capability: String
}

struct SessionCreateBridgeBanner: View {
  let store: HarnessMonitorStore
  let copy: SessionCreateBridgeBannerCopy

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(copy.title, systemImage: "exclamationmark.triangle")
        .scaledFont(.headline)
        .foregroundStyle(HarnessMonitorTheme.caution)
      if !copy.message.isEmpty {
        Text(copy.message)
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      if let enableLabel = copy.enableLabel {
        Button(enableLabel) {
          Task {
            _ = await store.setHostBridgeCapability(copy.capability, enabled: true)
          }
        }
        .disabled(store.isDaemonActionInFlight || store.isSessionActionInFlight)
      }
      if !copy.command.isEmpty {
        Text(copy.command)
          .scaledFont(.body.monospaced())
          .textSelection(.enabled)
          .padding(HarnessMonitorTheme.spacingSM)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            .quaternary.opacity(0.3),
            in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
          )
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(ChromeBannerSurfaceModifier(tint: HarnessMonitorTheme.caution))
    .accessibilityElement(children: .contain)
  }
}

enum SessionCreateBridgeBannerKind {
  case agentTui
  case acp
  case codex
}

extension SessionCreateBridgeBannerKind {
  var capability: String {
    switch self {
    case .agentTui: "agent-tui"
    case .acp: "acp"
    case .codex: "codex"
    }
  }

  @MainActor
  func copy(store: HarnessMonitorStore) -> SessionCreateBridgeBannerCopy {
    let state = store.hostBridgeCapabilityState(for: capability)
    let hostBridgeRunning = store.daemonStatus?.manifest?.hostBridge.running ?? false
    let title = bannerTitle(state: state)
    let message = bannerMessage(state: state, hostBridgeRunning: hostBridgeRunning)
    let command = store.hostBridgeStartCommand(for: capability)
    let enableLabel: String? = state == .excluded && hostBridgeRunning ? "Enable now" : nil
    return SessionCreateBridgeBannerCopy(
      title: title,
      message: message,
      command: command,
      enableLabel: enableLabel,
      capability: capability
    )
  }

  private func bannerTitle(
    state: HarnessMonitorStore.HostBridgeCapabilityState
  ) -> String {
    switch (self, state) {
    case (.agentTui, .excluded):
      return "Terminal agents are excluded from the host bridge"
    case (.agentTui, .unavailable):
      return "Terminal agent host bridge is not running"
    case (.agentTui, .ready):
      return "Terminal agent host bridge ready"
    case (.acp, .excluded):
      return "ACP is excluded from the host bridge"
    case (.acp, .unavailable):
      return "ACP host bridge is not running"
    case (.acp, .ready):
      return "ACP host bridge ready"
    case (.codex, .excluded):
      return "Codex is excluded from the host bridge"
    case (.codex, .unavailable):
      return "Codex host bridge is not running"
    case (.codex, .ready):
      return "Codex host bridge ready"
    }
  }

  private func bannerMessage(
    state: HarnessMonitorStore.HostBridgeCapabilityState,
    hostBridgeRunning: Bool
  ) -> String {
    switch (self, state) {
    case (.agentTui, .excluded):
      return "The shared host bridge is running without terminal control. "
        + "Enable it now or run this in a terminal:"
    case (.agentTui, .unavailable):
      return hostBridgeRunning
        ? "The shared host bridge is running, but terminal control is unavailable. "
          + "Re-enable it or run this in a terminal:"
        : "Harness Monitor runs sandboxed and needs the host bridge to start "
          + "or steer terminal-backed agents. Run this in a terminal:"
    case (.acp, .excluded):
      return "The shared host bridge is running without ACP enabled. "
        + "Enable it now or run this in a terminal:"
    case (.acp, .unavailable):
      return hostBridgeRunning
        ? "The shared host bridge is running, but ACP project access is unavailable. "
          + "Re-enable ACP or run this in a terminal:"
        : "Harness Monitor runs sandboxed and needs the host bridge to grant ACP "
          + "project access. Run this in a terminal:"
    case (.codex, .excluded):
      return "The shared host bridge is running without Codex enabled. "
        + "Enable it now or run this in a terminal:"
    case (.codex, .unavailable):
      return hostBridgeRunning
        ? "The shared host bridge is running, but the Codex capability is unavailable. "
          + "Re-enable it or run this in a terminal:"
        : "Harness Monitor runs sandboxed and needs the host bridge to start or steer "
          + "Codex threads. Run this in a terminal:"
    case (_, .ready):
      return ""
    }
  }
}

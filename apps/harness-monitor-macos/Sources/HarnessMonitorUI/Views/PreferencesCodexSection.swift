import HarnessMonitorKit
import SwiftUI

struct PreferencesHostBridgeSection: View {
  let store: HarnessMonitorStore
  @State private var pendingForcedDisableCapability: String?
  @State private var pendingForcedDisableMessage = ""

  private var manifest: DaemonManifest? {
    store.daemonStatus?.manifest
  }

  private var hostBridge: HostBridgeManifest {
    manifest?.hostBridge ?? HostBridgeManifest()
  }

  private var capabilityNames: [String] {
    let builtIns = ["codex", "agent-tui"]
    return Array(Set(builtIns).union(hostBridge.capabilities.keys)).sorted()
  }

  var body: some View {
    Form {
      Section("Host Bridge") {
        LabeledContent("Status") {
          HStack(spacing: HarnessMonitorTheme.spacingXS) {
            Circle()
              .fill(hostBridge.running ? .green : .secondary)
              .frame(width: 8, height: 8)
            Text(hostBridge.running ? "Running" : "Not running")
              .scaledFont(.body)
          }
        }
        LabeledContent("Socket") {
          Text(hostBridge.socketPath ?? "none")
            .scaledFont(.body.monospaced())
        }
        if manifest?.sandboxed == true {
          LabeledContent("Sandbox") {
            Text("Active")
              .scaledFont(.body)
              .foregroundStyle(.orange)
          }
        }
      }

      Section("Capabilities") {
        ForEach(capabilityNames, id: \.self) { name in
          capabilityRow(name: name)
        }
      }

      Section {
        HostBridgeCommandsView()
      } header: {
        Text("Setup")
      } footer: {
        Text(
          "Sandboxed monitor features use the shared host bridge. Start it once to enable every compiled capability, or narrow it with repeated --capability flags."
        )
        .scaledFont(.caption)
      }
    }
    .preferencesDetailFormStyle()
    .confirmationDialog(
      "Disable agent-tui capability?",
      isPresented: forceDisableConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Disable and stop sessions", role: .destructive) {
        guard let capability = pendingForcedDisableCapability else {
          return
        }
        pendingForcedDisableCapability = nil
        pendingForcedDisableMessage = ""
        Task {
          _ = await store.setHostBridgeCapability(capability, enabled: false, force: true)
        }
      }
      Button("Cancel", role: .cancel) {
        pendingForcedDisableCapability = nil
        pendingForcedDisableMessage = ""
      }
    } message: {
      Text(pendingForcedDisableMessage)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesCodexSection)
  }

  @ViewBuilder
  private func capabilityRow(name: String) -> some View {
    let capability = hostBridge.capabilities[name]
    let state = store.hostBridgeCapabilityState(for: name)
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack {
        Text(capabilityTitle(name))
          .scaledFont(.headline)
        Spacer()
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          Circle()
            .fill(capabilityColor(state))
            .frame(width: 8, height: 8)
          Text(capabilityStatusLabel(state))
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      if let capability {
        Text(capability.transport)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        if let endpoint = capability.endpoint {
          Text(endpoint)
            .scaledFont(.body.monospaced())
            .textSelection(.enabled)
        }
      } else {
        Text("Available to enable through the shared host bridge.")
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      if hostBridge.running {
        HStack {
          Spacer()
          Button(capabilityActionLabel(capability: capability, state: state)) {
            performCapabilityAction(name: name, capability: capability, state: state)
          }
          .harnessActionButtonStyle(
            variant: state == .ready ? .bordered : .prominent,
            tint: state == .ready ? .secondary : nil
          )
          .disabled(store.isDaemonActionInFlight)
        }
      }
    }
  }

  private var forceDisableConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingForcedDisableCapability != nil },
      set: { isPresented in
        if !isPresented {
          pendingForcedDisableCapability = nil
          pendingForcedDisableMessage = ""
        }
      }
    )
  }

  private func performCapabilityAction(
    name: String,
    capability: HostBridgeCapabilityManifest?,
    state: HarnessMonitorStore.HostBridgeCapabilityState
  ) {
    let shouldEnable = capability == nil || state != .ready
    Task {
      let result = await store.setHostBridgeCapability(name, enabled: shouldEnable)
      guard case .requiresForce(let message) = result, name == "agent-tui", !shouldEnable else {
        return
      }
      pendingForcedDisableCapability = name
      pendingForcedDisableMessage = message
    }
  }

  private func capabilityActionLabel(
    capability: HostBridgeCapabilityManifest?,
    state: HarnessMonitorStore.HostBridgeCapabilityState
  ) -> String {
    if capability == nil {
      return "Enable"
    }
    if state == .ready {
      return "Disable"
    }
    return "Restart"
  }

  private func capabilityTitle(_ name: String) -> String {
    switch name {
    case "agent-tui":
      "Agent TUI"
    case "codex":
      "Codex"
    default:
      name.replacingOccurrences(of: "-", with: " ").capitalized
    }
  }

  private func capabilityStatusLabel(
    _ state: HarnessMonitorStore.HostBridgeCapabilityState
  ) -> String {
    switch state {
    case .ready:
      "Healthy"
    case .excluded:
      "Excluded"
    case .unavailable:
      "Unavailable"
    }
  }

  private func capabilityColor(
    _ state: HarnessMonitorStore.HostBridgeCapabilityState
  ) -> Color {
    switch state {
    case .ready:
      .green
    case .excluded:
      .secondary
    case .unavailable:
      .orange
    }
  }
}

private struct HostBridgeCommandsView: View {
  private let startCommand = "harness bridge start"
  private let installCommand = "harness bridge install-launch-agent"

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      commandRow(
        title: "Start bridge",
        description: "Run once in a terminal to enable host-side capabilities",
        command: startCommand,
        accessibilityID: HarnessMonitorAccessibility.preferencesCodexCopyStartButton
      )
      commandRow(
        title: "Auto-start at login",
        description: "Install as a login item for persistent auto-start",
        command: installCommand,
        accessibilityID: HarnessMonitorAccessibility.preferencesCodexCopyInstallButton
      )
    }
  }

  private func commandRow(
    title: String,
    description: String,
    command: String,
    accessibilityID: String
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.headline)
      Text(description)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HStack {
        Text(command)
          .scaledFont(.body.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button("Copy") {
          HarnessMonitorClipboard.copy(command)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .accessibilityIdentifier(accessibilityID)
      }
    }
  }
}

#Preview("Preferences Host Bridge Section") {
  let store = PreferencesPreviewSupport.makeStore()

  PreferencesHostBridgeSection(store: store)
    .frame(width: 720)
}

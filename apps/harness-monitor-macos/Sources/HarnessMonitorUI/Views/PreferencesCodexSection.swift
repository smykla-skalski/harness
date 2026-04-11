import HarnessMonitorKit
import SwiftUI

struct PreferencesHostBridgeSection: View {
  let store: HarnessMonitorStore

  private var manifest: DaemonManifest? {
    store.daemonStatus?.manifest
  }

  private var hostBridge: HostBridgeManifest {
    manifest?.hostBridge ?? HostBridgeManifest()
  }

  private var capabilities: [(String, HostBridgeCapabilityManifest)] {
    hostBridge.capabilities.sorted { $0.key < $1.key }
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
        if capabilities.isEmpty {
          Text("No capabilities enabled")
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        } else {
          ForEach(capabilities, id: \.0) { name, capability in
            capabilityRow(name: name, capability: capability)
          }
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
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesCodexSection)
  }

  @ViewBuilder
  private func capabilityRow(name: String, capability: HostBridgeCapabilityManifest) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack {
        Text(name)
          .scaledFont(.headline)
        Spacer()
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          Circle()
            .fill(capability.healthy ? .green : .orange)
            .frame(width: 8, height: 8)
          Text(capability.healthy ? "Healthy" : "Unavailable")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      Text(capability.transport)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if let endpoint = capability.endpoint {
        Text(endpoint)
          .scaledFont(.body.monospaced())
          .textSelection(.enabled)
      }
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
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(command, forType: .string)
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

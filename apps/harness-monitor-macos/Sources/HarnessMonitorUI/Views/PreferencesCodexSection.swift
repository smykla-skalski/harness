import HarnessMonitorKit
import SwiftUI

struct PreferencesCodexSection: View {
  let store: HarnessMonitorStore

  private var manifest: DaemonManifest? {
    store.daemonStatus?.manifest
  }

  private var transportLabel: String {
    manifest?.codexTransport ?? "unknown"
  }

  private var endpointLabel: String {
    manifest?.codexEndpoint ?? "none"
  }

  private var isBridgeConnected: Bool {
    manifest?.codexTransport == "websocket" && manifest?.codexEndpoint != nil
  }

  var body: some View {
    Form {
      Section("Bridge status") {
        LabeledContent("Transport") {
          Text(transportLabel)
            .scaledFont(.body.monospaced())
        }
        LabeledContent("Endpoint") {
          Text(endpointLabel)
            .scaledFont(.body.monospaced())
        }
        LabeledContent("Status") {
          HStack(spacing: HarnessMonitorTheme.spacingXS) {
            Circle()
              .fill(isBridgeConnected ? .green : .secondary)
              .frame(width: 8, height: 8)
            Text(isBridgeConnected ? "Connected" : "Not connected")
              .scaledFont(.body)
          }
        }
        if manifest?.sandboxed == true {
          LabeledContent("Sandbox") {
            Text("Active")
              .scaledFont(.body)
              .foregroundStyle(.orange)
          }
        }
      }
      Section {
        CodexBridgeCommandsView()
      } header: {
        Text("Setup")
      } footer: {
        Text(
          "The sandboxed daemon connects to Codex over WebSocket. Run the bridge in a terminal to make Codex available."
        )
        .scaledFont(.caption)
      }
    }
    .preferencesDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesCodexSection)
  }
}

private struct CodexBridgeCommandsView: View {
  @State private var copied = false

  private let startCommand = "harness codex-bridge start"
  private let installCommand = "harness codex-bridge install-launch-agent"

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      commandRow(
        title: "Start bridge",
        description: "Run once in a terminal to start Codex",
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

#Preview("Preferences Codex Section") {
  let store = PreferencesPreviewSupport.makeStore()

  PreferencesCodexSection(store: store)
    .frame(width: 720)
}

import HarnessMonitorKit
import SwiftUI

/// Settings UI for the in-app MCP accessibility registry host.
///
/// A single master toggle controls whether Harness Monitor exposes its
/// accessibility registry over a Unix-domain socket in the app-group
/// container. The toggle is persisted in `@AppStorage` and defaults to
/// **on** so MCP stays available from first launch unless the user disables it.
public struct SettingsMCPSection: View {
  public let store: HarnessMonitorStore
  public let isActive: Bool
  @AppStorage(HarnessMonitorMCPSettingsDefaults.registryHostEnabledKey)
  private var registryHostEnabled = HarnessMonitorMCPSettingsDefaults
    .registryHostEnabledDefault
  @State private var cachedSnapshot: SettingsMCPSnapshot?

  public init(store: HarnessMonitorStore, isActive: Bool = true) {
    self.store = store
    self.isActive = isActive
  }

  private var forceEnabled: Bool {
    HarnessMonitorMCPSettingsDefaults.forceEnableFromEnvironment
  }

  public var body: some View {
    let activeSnapshot = isActive ? SettingsMCPSnapshot(store: store) : nil
    let snapshot = activeSnapshot ?? cachedSnapshot
    if isActive {
      activeBody(snapshot: snapshot, activeSnapshot: activeSnapshot)
    } else {
      Color.clear
    }
  }

  private func activeBody(
    snapshot: SettingsMCPSnapshot?,
    activeSnapshot: SettingsMCPSnapshot?
  ) -> some View {
    Form {
      if let snapshot {
        Section {
          Toggle("Expose accessibility registry to MCP clients", isOn: $registryHostEnabled)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.settingsMCPRegistryHostToggle
            )
            .accessibilityHint(
              Text(
                forceEnabled
                  ? forceEnabledMessage
                  : "Turns the MCP accessibility registry host on or off"
              )
            )
            .disabled(forceEnabled)
          if forceEnabled {
            Text(forceEnabledMessage)
              .scaledFont(.caption)
              .foregroundStyle(.orange)
          }
          statusRow(snapshot)
          Text(snapshot.status.detail)
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
          if let recoverySummary = snapshot.status.recoverySummary {
            Text(recoverySummary)
              .scaledFont(.caption)
              .foregroundStyle(.secondary)
          }
          socketPathRow(snapshot)
        } header: {
          Text("Accessibility Registry")
        } footer: {
          Text(footerAttributed)
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
        }
      } else {
        ProgressView("Loading MCP status...")
      }
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMCPSection)
    .task(id: activeSnapshot) {
      guard let activeSnapshot else { return }
      cachedSnapshot = activeSnapshot
    }
  }

  private var forceEnabledMessage: String {
    let envVar = HarnessMonitorMCPSettingsDefaults.forceEnableEnvVar
    return "\(envVar) is set in this DEBUG build; the host is forced on "
      + "regardless of the toggle"
  }

  private var footerAttributed: AttributedString {
    var string = AttributedString(
      "When enabled, Harness Monitor binds a Unix-domain socket inside the "
        + "app-group container so the "
    )
    var code = AttributedString("harness mcp serve")
    code.font = .footnote.monospaced()
    code.backgroundColor = HarnessMonitorTheme.accent.opacity(0.12)
    code.foregroundColor = HarnessMonitorTheme.ink
    string.append(code)
    string.append(
      AttributedString(
        " MCP server can read app-published windows and registry-backed "
          + "controls. MCP clients still resolve some live accessibility "
          + "queries and input actions through the bundled helper, and the "
          + "client process still needs Accessibility permission in System "
          + "Settings"
      )
    )
    return string
  }

  private func statusRow(_ snapshot: SettingsMCPSnapshot) -> some View {
    LabeledContent("Status") {
      MCPStatusLabel(status: snapshot.status, variant: .detail)
    }
    .help(snapshot.status.detail)
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMCPStatus)
  }

  @ViewBuilder private func socketPathRow(_ snapshot: SettingsMCPSnapshot) -> some View {
    if let socketPath = snapshot.socketPath {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Text("Socket path:")
          .fixedSize(horizontal: true, vertical: false)
        Text(socketPath)
          .monospaced()
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scaledFont(.caption)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(Text("Socket path: \(socketPath)"))
    } else {
      Text("Socket path: unavailable (app-group container not resolved)")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct SettingsMCPSnapshot: Equatable {
  let status: HarnessMonitorMCPStatusSnapshot
  let fallbackSocketPath: String?

  @MainActor
  init(store: HarnessMonitorStore) {
    status = store.mcpStatus
    fallbackSocketPath = HarnessMonitorMCPSocketPath.resolved()?.path
  }

  var socketPath: String? {
    status.socketPath ?? fallbackSocketPath
  }
}

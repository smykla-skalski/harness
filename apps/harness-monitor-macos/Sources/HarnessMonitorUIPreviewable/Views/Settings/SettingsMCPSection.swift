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
  @AppStorage(HarnessMonitorMCPSettingsDefaults.registryHostEnabledKey)
  private var registryHostEnabled = HarnessMonitorMCPSettingsDefaults
    .registryHostEnabledDefault

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  private var forceEnabled: Bool {
    HarnessMonitorMCPSettingsDefaults.forceEnableFromEnvironment
  }

  public var body: some View {
    Form {
      Section {
        Toggle("Expose accessibility registry to MCP clients", isOn: $registryHostEnabled)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsMCPRegistryHostToggle
          )
          .accessibilityHint(
            Text(
              forceEnabled
                ? forceEnabledMessage
                : "Turns the MCP accessibility registry host on or off."
            )
          )
          .disabled(forceEnabled)
        if forceEnabled {
          Text(forceEnabledMessage)
            .scaledFont(.caption)
            .foregroundStyle(.orange)
        }
        statusRow
        Text(store.mcpStatus.detail)
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
        if let recoverySummary = store.mcpStatus.recoverySummary {
          Text(recoverySummary)
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }
        socketPathRow
      } header: {
        Text("Accessibility Registry")
      } footer: {
        Text(footerAttributed)
          .scaledFont(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMCPSection)
  }

  private var forceEnabledMessage: String {
    let envVar = HarnessMonitorMCPSettingsDefaults.forceEnableEnvVar
    return "\(envVar) is set in this DEBUG build; the host is forced on "
      + "regardless of the toggle."
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
          + "Settings."
      )
    )
    return string
  }

  private var statusRow: some View {
    LabeledContent("Status") {
      MCPStatusLabel(status: store.mcpStatus, variant: .detail)
    }
    .help(store.mcpStatus.detail)
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMCPStatus)
  }

  @ViewBuilder private var socketPathRow: some View {
    if let socketPath = store.mcpStatus.socketPath ?? HarnessMonitorMCPSocketPath.resolved()?.path {
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

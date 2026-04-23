import HarnessMonitorKit
import SwiftUI

/// Preferences UI for the in-app MCP accessibility registry host.
///
/// A single master toggle controls whether Harness Monitor exposes its
/// accessibility registry over a Unix-domain socket in the app-group
/// container. The toggle is persisted in `@AppStorage` and defaults to
/// off so the app introduces no socket surface unless the user opts in.
public struct PreferencesMCPSection: View {
  @AppStorage(HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
  private var registryHostEnabled = HarnessMonitorMCPPreferencesDefaults
    .registryHostEnabledDefault

  public init() {}

  private var forceEnabled: Bool {
    HarnessMonitorMCPPreferencesDefaults.forceEnableFromEnvironment
  }

  public var body: some View {
    Form {
      Section {
        Toggle("Expose accessibility registry to MCP clients", isOn: $registryHostEnabled)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.preferencesMCPRegistryHostToggle
          )
          .disabled(forceEnabled)
        if forceEnabled {
          Text(forceEnabledMessage)
            .scaledFont(.caption)
            .foregroundStyle(.orange)
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
    .preferencesDetailFormStyle()
  }

  private var forceEnabledMessage: String {
    let envVar = HarnessMonitorMCPPreferencesDefaults.forceEnableEnvVar
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
        " MCP server can enumerate windows and elements, click UI, and type "
          + "text. Clients still need Accessibility permission in System Settings."
      )
    )
    return string
  }

  @ViewBuilder private var socketPathRow: some View {
    if let socket = HarnessMonitorMCPSocketPath.resolved() {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Text("Socket path:")
          .fixedSize(horizontal: true, vertical: false)
        Text(socket.path)
          .monospaced()
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scaledFont(.caption)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(Text("Socket path: \(socket.path)"))
    } else {
      Text("Socket path: unavailable (app-group container not resolved)")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

#Preview("Preferences MCP") {
  PreferencesMCPSection()
    .frame(width: 520, height: 260)
}

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

  public var body: some View {
    Form {
      Section {
        Toggle("Expose accessibility registry to MCP clients", isOn: $registryHostEnabled)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.preferencesMCPRegistryHostToggle
          )
        Text(socketDescription)
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
      } header: {
        Text("Accessibility Registry")
      } footer: {
        Text(
          "When enabled, Harness Monitor binds a Unix-domain socket inside the "
            + "app-group container so the `harness mcp serve` MCP server can "
            + "enumerate windows and elements, click UI, and type text. "
            + "Clients still need Accessibility permission in System Settings."
        )
        .scaledFont(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .preferencesDetailFormStyle()
  }

  private var socketDescription: String {
    if let socket = HarnessMonitorMCPSocketPath.resolved() {
      "Socket path: \(socket.path)"
    } else {
      "Socket path: unavailable (app-group container not resolved)"
    }
  }
}

#Preview("Preferences MCP") {
  PreferencesMCPSection()
    .frame(width: 520, height: 260)
}

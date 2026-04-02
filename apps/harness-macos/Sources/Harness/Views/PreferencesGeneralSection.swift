import HarnessKit
import SwiftUI

struct PreferencesGeneralSection: View {
  @Binding var themeMode: HarnessThemeMode
  @AppStorage(HarnessTextSize.storageKey)
  private var textSizeIndex = HarnessTextSize.defaultIndex
  let endpoint: String
  let version: String
  let launchAgentState: String
  let launchAgentCaption: String
  let cacheEntryCount: Int
  let sessionCount: Int
  let startedAt: String?
  let lastError: String?
  let lastAction: String
  let isLoading: Bool
  let reconnect: HarnessAsyncActionButton.Action
  let refreshDiagnostics: HarnessAsyncActionButton.Action
  let startDaemon: HarnessAsyncActionButton.Action
  let installLaunchAgent: HarnessAsyncActionButton.Action
  let removeLaunchAgent: HarnessAsyncActionButton.Action

  var body: some View {
    Form {
      Section {
        Picker("Mode", selection: $themeMode) {
          ForEach(HarnessThemeMode.allCases) {
            Text($0.label).tag($0)
          }
        }
        .accessibilityIdentifier(HarnessAccessibility.preferencesThemeModePicker)
        Picker("Text size", selection: $textSizeIndex) {
          ForEach(Array(HarnessTextSize.scales.enumerated()), id: \.offset) { index, level in
            Text(level.label).tag(index)
          }
        }
        .accessibilityIdentifier(HarnessAccessibility.preferencesTextSizePicker)
      } header: {
        Text("Appearance")
      } footer: {
        Text("Applies to every Harness window on this Mac.")
      }

      Section("Actions") {
        PreferencesActionButtons(
          isLoading: isLoading,
          reconnect: reconnect,
          refreshDiagnostics: refreshDiagnostics,
          startDaemon: startDaemon,
          installLaunchAgent: installLaunchAgent,
          removeLaunchAgent: removeLaunchAgent
        )
      }

      Section("Overview") {
        LabeledContent("Endpoint", value: endpoint)
          .textSelection(.enabled)
          .accessibilityIdentifier(HarnessAccessibility.preferencesMetricCard("Endpoint"))
        LabeledContent("Version", value: version)
          .textSelection(.enabled)
          .accessibilityIdentifier(HarnessAccessibility.preferencesMetricCard("Version"))
        LabeledContent("Launchd") {
          VStack(alignment: .trailing, spacing: 2) {
            Text(launchAgentState)
            Text(launchAgentCaption)
              .scaledFont(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier(HarnessAccessibility.preferencesMetricCard("Launchd"))
        LabeledContent("Cached Sessions") {
          Text("\(cacheEntryCount)")
        }
        .accessibilityIdentifier(HarnessAccessibility.preferencesMetricCard("Cached Sessions"))
        LabeledContent("Live Sessions") {
          Text("\(sessionCount)")
        }
      }

      PreferencesStatusSection(
        startedAt: startedAt,
        lastError: lastError,
        lastAction: lastAction
      )
    }
    .preferencesDetailFormStyle()
  }
}

#Preview("Preferences General Section") {
  @Previewable @State var themeMode: HarnessThemeMode = .dark
  let store = PreferencesPreviewSupport.makeStore()

  PreferencesGeneralSection(
    themeMode: $themeMode,
    endpoint: store.diagnostics?.health?.endpoint ?? store.health?.endpoint ?? "Unavailable",
    version: store.diagnostics?.health?.version ?? store.health?.version ?? "Unavailable",
    launchAgentState: store.daemonStatus?.launchAgent.lifecycleTitle ?? "Manual",
    launchAgentCaption: PreferencesPreviewSupport.launchAgentCaption(for: store),
    cacheEntryCount: PreferencesPreviewSupport.cacheEntryCount(for: store),
    sessionCount: store.daemonStatus?.sessionCount ?? store.sessions.count,
    startedAt: store.diagnostics?.health?.startedAt ?? store.health?.startedAt,
    lastError: store.lastError,
    lastAction: store.lastAction,
    isLoading: false,
    reconnect: { await store.reconnect() },
    refreshDiagnostics: { await store.refreshDiagnostics() },
    startDaemon: { await store.startDaemon() },
    installLaunchAgent: { await store.installLaunchAgent() },
    removeLaunchAgent: { store.requestRemoveLaunchAgentConfirmation() }
  )
  .frame(width: 720)
}

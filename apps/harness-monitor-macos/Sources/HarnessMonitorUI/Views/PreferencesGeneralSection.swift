import HarnessMonitorKit
import SwiftUI

struct PreferencesGeneralSection: View {
  let store: HarnessMonitorStore
  @Binding var themeMode: HarnessMonitorThemeMode
  @AppStorage(HarnessMonitorTextSize.storageKey)
  private var textSizeIndex = HarnessMonitorTextSize.defaultIndex
  @State private var isRemoveLaunchAgentConfirmationPresented = false

  private var effectiveHealth: HealthResponse? {
    store.diagnostics?.health ?? store.health
  }

  private var endpoint: String {
    effectiveHealth?.endpoint
      ?? store.daemonStatus?.manifest?.endpoint ?? "Unavailable"
  }

  private var version: String {
    effectiveHealth?.version
      ?? store.daemonStatus?.manifest?.version ?? "Unavailable"
  }

  private var launchAgentState: String {
    store.daemonStatus?.launchAgent.lifecycleTitle ?? "Manual"
  }

  private var launchAgentCaption: String {
    let agent = store.daemonStatus?.launchAgent
    let fallback = agent?.label ?? "Launch agent"
    let caption = agent?.lifecycleCaption ?? fallback
    return caption.isEmpty ? fallback : caption
  }

  private var cacheEntryCount: Int {
    store.diagnostics?.workspace.cacheEntryCount
      ?? store.daemonStatus?.diagnostics.cacheEntryCount ?? 0
  }

  private var sessionCount: Int {
    store.daemonStatus?.sessionCount ?? store.sessions.count
  }

  private var startedAt: String? {
    effectiveHealth?.startedAt ?? store.daemonStatus?.manifest?.startedAt
  }

  private var isLoading: Bool {
    store.isDaemonActionInFlight
      || store.isDiagnosticsRefreshInFlight
      || store.connectionState == .connecting
  }

  var body: some View {
    Form {
      Section {
        Picker("Mode", selection: $themeMode) {
          ForEach(HarnessMonitorThemeMode.allCases) {
            Text($0.label).tag($0)
          }
        }
        .harnessNativeFormControl()
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesThemeModePicker)
        Picker("Text size", selection: $textSizeIndex) {
          ForEach(Array(HarnessMonitorTextSize.scales.enumerated()), id: \.offset) { index, level in
            Text(level.label).tag(index)
          }
        }
        .harnessNativeFormControl()
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesTextSizePicker)
      } header: {
        Text("Appearance")
      } footer: {
        Text("Applies to every Harness Monitor window on this Mac.")
      }

      Section("Actions") {
        PreferencesActionButtons(
          store: store,
          isLoading: isLoading,
          isRemoveLaunchAgentConfirmationPresented: $isRemoveLaunchAgentConfirmationPresented
        )
      }

      Section("Overview") {
        LabeledContent("Endpoint", value: endpoint)
          .textSelection(.enabled)
          .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Endpoint"))
        LabeledContent("Version", value: version)
          .textSelection(.enabled)
          .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Version"))
        LabeledContent("Launchd") {
          VStack(alignment: .trailing, spacing: 2) {
            Text(launchAgentState)
            Text(launchAgentCaption)
              .scaledFont(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Launchd"))
        LabeledContent("Cached Sessions") {
          Text("\(cacheEntryCount)")
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Cached Sessions"))
        LabeledContent("Live Sessions") {
          Text("\(sessionCount)")
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Live Sessions"))
      }

      PreferencesStatusSection(
        startedAt: startedAt,
        lastError: store.lastError,
        lastAction: store.lastAction
      )
    }
    .preferencesDetailFormStyle()
    .confirmationDialog(
      "Remove Launch Agent?",
      isPresented: $isRemoveLaunchAgentConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Remove Launch Agent Now", role: .destructive) {
        Task { await store.removeLaunchAgent() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This disables launchd residency for the harness daemon on this Mac.")
    }
  }
}

#Preview("Preferences General Section") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .dark

  PreferencesGeneralSection(
    store: PreferencesPreviewSupport.makeStore(),
    themeMode: $themeMode
  )
  .frame(width: 720)
}

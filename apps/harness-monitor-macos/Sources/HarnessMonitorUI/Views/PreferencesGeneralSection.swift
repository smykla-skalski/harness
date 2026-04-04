import HarnessMonitorKit
import SwiftUI

struct PreferencesGeneralSection: View {
  let store: HarnessMonitorStore
  @Binding var themeMode: HarnessMonitorThemeMode
  @AppStorage(HarnessMonitorTextSize.storageKey)
  private var textSizeIndex = HarnessMonitorTextSize.defaultIndex
  @AppStorage(HarnessMonitorDateTimeConfiguration.timeZoneModeKey)
  private var timeZoneModeRawValue = HarnessMonitorDateTimeConfiguration.defaultTimeZoneModeRawValue
  @AppStorage(HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey)
  private var customTimeZoneIdentifier = HarnessMonitorDateTimeConfiguration.defaultCustomTimeZoneIdentifier
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

  private var databaseSize: String {
    let bytes = store.diagnostics?.workspace.databaseSizeBytes
      ?? store.daemonStatus?.diagnostics.databaseSizeBytes ?? 0
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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

  private var dateTimeConfiguration: HarnessMonitorDateTimeConfiguration {
    HarnessMonitorDateTimeConfiguration(
      timeZoneModeRawValue: timeZoneModeRawValue,
      customTimeZoneIdentifier: customTimeZoneIdentifier
    )
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

      Section {
        Picker("Time zone", selection: $timeZoneModeRawValue) {
          ForEach(HarnessMonitorDateTimeZoneMode.allCases) { mode in
            Text(mode.label).tag(mode.rawValue)
          }
        }
        .harnessNativeFormControl()
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesTimeZoneModePicker)

        if dateTimeConfiguration.showsCustomTimeZoneField {
          Picker("Custom zone", selection: $customTimeZoneIdentifier) {
            ForEach(HarnessMonitorDateTimeConfiguration.knownTimeZoneIdentifiers, id: \.self) {
              identifier in
              Text(identifier).tag(identifier)
            }
          }
            .harnessNativeFormControl()
            .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesCustomTimeZonePicker)
        }

        LabeledContent("Resolved Zone", value: dateTimeConfiguration.effectiveTimeZoneDisplayName)
        LabeledContent(
          "Preview",
          value: formatTimestamp(
            HarnessMonitorDateTimeConfiguration.previewTimestampValue,
            configuration: dateTimeConfiguration
          )
        )
      } header: {
        Text("Date & Time")
      } footer: {
        Text("Every timestamp in Harness Monitor uses this timezone-aware display format.")
      }

      Section {
        PreferencesActionButtons(
          store: store,
          isLoading: isLoading,
          isRemoveLaunchAgentConfirmationPresented: $isRemoveLaunchAgentConfirmationPresented
        )
      } header: {
        Text("Actions")
      }

      Section {
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
        LabeledContent("Database Size") {
          Text(databaseSize)
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Database Size"))
        LabeledContent("Live Sessions") {
          Text("\(sessionCount)")
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Live Sessions"))
      } header: {
        Text("Overview")
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

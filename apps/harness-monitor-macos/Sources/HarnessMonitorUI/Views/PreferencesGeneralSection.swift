import HarnessMonitorKit
import SwiftUI

struct PreferencesGeneralSection: View {
  let store: HarnessMonitorStore
  @Binding var themeMode: HarnessMonitorThemeMode
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection.storageValue
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

  private static let logLevels = ["trace", "debug", "info", "warn", "error"]

  private var daemonLogLevelBinding: Binding<String> {
    Binding(
      get: { store.daemonLogLevel ?? "info" },
      set: { newValue in
        store.daemonLogLevel = newValue
        Task { await store.setDaemonLogLevel(newValue) }
      }
    )
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

  private var selectedBackground: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
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

        Picker("Backdrop", selection: $backdropModeRawValue) {
          ForEach(HarnessMonitorBackdropMode.allCases) { mode in
            Text(mode.label).tag(mode.rawValue)
          }
        }
        .harnessNativeFormControl()
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesBackdropModePicker)

        PreferencesBackgroundGallery(
          selection: $backgroundImageRawValue,
          backdropModeRawValue: $backdropModeRawValue,
          selectedBackground: selectedBackground
        )

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
        Text(
          "Mode and text size apply to every Harness Monitor window. Backdrop controls where the softened background image renders, and choosing an image turns on the window backdrop if it is currently off."
        )
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
        Text("Every timestamp in Harness Monitor uses this timezone-aware display format")
          .accessibilityIdentifier("harness.preferences.footer.datetime")
      }

      Section {
        Picker("Log level", selection: daemonLogLevelBinding) {
          ForEach(Self.logLevels, id: \.self) { level in
            Text(level.uppercased()).tag(level)
          }
        }
        .harnessNativeFormControl()
        .disabled(store.connectionState != .online)
        .accessibilityIdentifier("harness.preferences.daemon.logLevel")
      } header: {
        Text("Daemon")
      } footer: {
        Text("Changes apply immediately and reset when the daemon restarts")
          .accessibilityIdentifier("harness.preferences.footer.daemon")
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

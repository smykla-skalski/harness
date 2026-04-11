import HarnessMonitorKit
import SwiftUI

struct PreferencesAppearanceSection: View {
  @Binding var themeMode: HarnessMonitorThemeMode
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection
    .storageValue
  @AppStorage(HarnessMonitorTextSize.storageKey)
  private var textSizeIndex = HarnessMonitorTextSize.defaultIndex
  @AppStorage(HarnessMonitorCornerAnimationDefaults.enabledKey)
  private var cornerAnimationEnabled = false
  @State private var selectedBackgroundTab: BackgroundCollectionTab = .featured

  private var selectedBackground: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
  }

  var body: some View {
    Form {
      Section {
        Picker("Theme mode", selection: $themeMode) {
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

        Picker("Backdrop", selection: $backdropModeRawValue) {
          ForEach(HarnessMonitorBackdropMode.allCases) { mode in
            Text(mode.label).tag(mode.rawValue)
          }
        }
        .harnessNativeFormControl()
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesBackdropModePicker)

        Toggle("Corner animation", isOn: $cornerAnimationEnabled)
          .harnessNativeFormControl()
          .accessibilityIdentifier("harness.preferences.appearance.cornerAnimation")
      } header: {
        Text("Appearance")
      } footer: {
        Text(
          "Theme mode and text size apply to every Harness Monitor window."
            + " Backdrop controls where the softened background image renders,"
            + " and choosing an image turns on the window backdrop if it is currently off."
            + " Corner animation shows a dancing llama during activity."
        )
      }

      backgroundImageSection
    }
    .preferencesDetailFormStyle()
    .onAppear(perform: selectTabForCurrentBackground)
    .onChange(of: selectedBackground.storageValue) { _, _ in
      selectTabForCurrentBackground()
    }
  }

  private var isBackdropDisabled: Bool {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) == HarnessMonitorBackdropMode.none
  }

  private var backgroundImageSection: some View {
    HarnessMonitorTabbedContent(
      title: "Background image",
      selection: $selectedBackgroundTab,
      tabTitle: \.title,
      alignment: .trailing,
      tabsDisabled: isBackdropDisabled
    ) { tab in
      PreferencesBackgroundGallery(
        selection: $backgroundImageRawValue,
        backdropModeRawValue: $backdropModeRawValue,
        selectedBackground: selectedBackground,
        collection: tab.collection
      )
    }
  }

  private func selectTabForCurrentBackground() {
    if case .system = selectedBackground.source {
      selectedBackgroundTab = .native
    }
  }
}

private enum BackgroundCollectionTab: String, CaseIterable, Identifiable {
  case featured
  case native

  var id: String { rawValue }

  var title: String {
    switch self {
    case .featured: "Featured"
    case .native: "Native"
    }
  }

  var collection: BackgroundCollection {
    switch self {
    case .featured: .featured
    case .native: .native
    }
  }
}

enum BackgroundCollection {
  case featured
  case native
}

struct PreferencesGeneralSection: View {
  let store: HarnessMonitorStore
  @AppStorage(HarnessMonitorDateTimeConfiguration.timeZoneModeKey)
  private var timeZoneModeRawValue = HarnessMonitorDateTimeConfiguration.defaultTimeZoneModeRawValue
  @AppStorage(HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey)
  private var customTimeZoneIdentifier = HarnessMonitorDateTimeConfiguration
    .defaultCustomTimeZoneIdentifier
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

  private var sandboxManifest: DaemonManifest? {
    store.daemonStatus?.manifest
  }

  private var databaseSize: String {
    let bytes =
      store.diagnostics?.workspace.databaseSizeBytes
      ?? store.daemonStatus?.diagnostics.databaseSizeBytes ?? 0
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private var sessionCount: Int {
    store.daemonStatus?.sessionCount ?? store.sessions.count
  }

  private var startedAt: String? {
    effectiveHealth?.startedAt ?? store.daemonStatus?.manifest?.startedAt
  }

  private var daemonModeLabel: String {
    switch store.daemonOwnership {
    case .managed:
      "Managed (SMAppService)"
    case .external:
      "External (CLI)"
    }
  }

  private var externalDaemonCommand: String {
    "harness daemon dev"
  }

  private var externalDaemonManifestPath: String {
    HarnessMonitorPaths.manifestURL().path
  }

  private var externalDaemonProcessSummary: String? {
    guard let manifest = store.daemonStatus?.manifest else {
      return nil
    }
    return "pid \(manifest.pid) · \(manifest.endpoint)"
  }

  @ViewBuilder
  private var daemonModeRow: some View {
    LabeledContent("Daemon mode") {
      VStack(alignment: .trailing, spacing: 2) {
        Text(daemonModeLabel)
        if store.daemonOwnership == .external {
          Text("Run `\(externalDaemonCommand)` in a terminal")
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Daemon Mode"))
    if store.daemonOwnership == .external {
      LabeledContent("Dev manifest") {
        Text(externalDaemonManifestPath)
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .multilineTextAlignment(.trailing)
      }
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.preferencesMetricCard("Dev Manifest")
      )
      if let summary = externalDaemonProcessSummary {
        LabeledContent("Dev daemon") {
          Text(summary)
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.preferencesMetricCard("Dev Daemon")
        )
      }
    }
  }

  private static let logLevels = ["trace", "debug", "info", "warn", "error"]

  private var daemonLogLevelBinding: Binding<String> {
    Binding(
      get: { store.daemonLogLevel ?? HarnessMonitorLogger.defaultDaemonLogLevel },
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

  var body: some View {
    Form {
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
            ForEach(
              HarnessMonitorDateTimeConfiguration.knownTimeZoneIdentifiers,
              id: \.self
            ) { identifier in
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
        daemonModeRow
        if store.daemonOwnership == .managed {
          LabeledContent("Launchd") {
            VStack(alignment: .trailing, spacing: 2) {
              Text(launchAgentState)
              Text(launchAgentCaption)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Launchd"))
        }
        LabeledContent("Sandbox") {
          if sandboxManifest?.sandboxed == true {
            Text("Enabled")
              .scaledFont(.caption)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(HarnessMonitorTheme.accent.opacity(0.18), in: Capsule())
              .foregroundStyle(HarnessMonitorTheme.accent)
          } else {
            Text(sandboxManifest == nil ? "Unknown" : "Off")
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Sandbox"))
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

#Preview("Preferences Appearance Section") {
  @Previewable @State var themeMode: HarnessMonitorThemeMode = .dark

  PreferencesAppearanceSection(themeMode: $themeMode)
    .frame(width: 720)
}

#Preview("Preferences General Section") {
  PreferencesGeneralSection(
    store: PreferencesPreviewSupport.makeStore()
  )
  .frame(width: 720)
}

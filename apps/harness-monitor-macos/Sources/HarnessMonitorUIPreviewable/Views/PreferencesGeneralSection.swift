import HarnessMonitorKit
import SwiftUI

public struct PreferencesAppearanceSection: View {
  @Binding public var themeMode: HarnessMonitorThemeMode
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

  public init(themeMode: Binding<HarnessMonitorThemeMode>) {
    _themeMode = themeMode
  }

  private var selectedBackground: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
  }

  public var body: some View {
    Form {
      Section {
        Picker("Theme mode", selection: $themeMode) {
          ForEach(HarnessMonitorThemeMode.allCases) {
            Text($0.label).tag($0)
          }
        }
        .harnessNativeFormControl()
        .accessibilityHint("Changes the color scheme for all windows")
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesThemeModePicker)

        Picker("Text size", selection: $textSizeIndex) {
          ForEach(Array(HarnessMonitorTextSize.scales.enumerated()), id: \.offset) { index, level in
            Text(level.label).tag(index)
          }
        }
        .harnessNativeFormControl()
        .accessibilityHint("Scales text throughout the application")
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesTextSizePicker)

        Picker("Backdrop", selection: $backdropModeRawValue) {
          ForEach(HarnessMonitorBackdropMode.allCases) { mode in
            Text(mode.label).tag(mode.rawValue)
          }
        }
        .harnessNativeFormControl()
        .accessibilityHint("Controls where the background image renders")
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesBackdropModePicker)

        Toggle("Corner animation", isOn: $cornerAnimationEnabled)
          .harnessNativeFormControl()
          .accessibilityHint("Shows a dancing llama during activity")
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
      tabsDisabled: isBackdropDisabled,
      pickerAccessibilityIdentifier: HarnessMonitorAccessibility
        .preferencesBackgroundCollectionPicker
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

public struct PreferencesGeneralOverviewState {
  public enum SandboxState: Equatable {
    case enabled
    case off
    case unknown
  }

  public let endpoint: String
  public let version: String
  public let launchAgentState: String
  public let launchAgentCaption: String
  public let sandboxState: SandboxState
  public let databaseSize: String
  public let sessionCount: Int
  public let startedAt: String?
  public let daemonModeLabel: String
  public let isExternalDaemon: Bool
  public let externalDaemonManifestPath: String
  public let externalDaemonProcessSummary: String?
  public let showsLaunchAgent: Bool

  @MainActor
  public init(store: HarnessMonitorStore) {
    let effectiveHealth = store.diagnostics?.health ?? store.health
    let launchAgent = store.daemonStatus?.launchAgent
    let manifest = store.daemonStatus?.manifest
    let databaseSizeBytes =
      store.diagnostics?.workspace.databaseSizeBytes
      ?? store.daemonStatus?.diagnostics.databaseSizeBytes
      ?? 0

    endpoint = effectiveHealth?.endpoint ?? manifest?.endpoint ?? "Unavailable"
    version = effectiveHealth?.version ?? manifest?.version ?? "Unavailable"
    launchAgentState = launchAgent?.lifecycleTitle ?? "Manual"
    let launchAgentFallback = launchAgent?.label ?? "Launch agent"
    let launchAgentCaption = launchAgent?.lifecycleCaption ?? launchAgentFallback
    self.launchAgentCaption = launchAgentCaption.isEmpty ? launchAgentFallback : launchAgentCaption
    databaseSize = DatabaseStatistics.formatByteCount(Int64(databaseSizeBytes))
    sessionCount = store.daemonStatus?.sessionCount ?? store.sessions.count
    startedAt = effectiveHealth?.startedAt ?? manifest?.startedAt
    externalDaemonManifestPath = HarnessMonitorPaths.manifestURL().path
    externalDaemonProcessSummary =
      if let manifest {
        "pid \(manifest.pid) · \(manifest.endpoint)"
      } else {
        nil
      }

    switch store.daemonOwnership {
    case .managed:
      daemonModeLabel = "Managed (SMAppService)"
      isExternalDaemon = false
      showsLaunchAgent = true
    case .external:
      daemonModeLabel = "External (CLI)"
      isExternalDaemon = true
      showsLaunchAgent = false
    }

    if let sandboxed = manifest?.sandboxed {
      sandboxState = sandboxed ? .enabled : .off
    } else {
      sandboxState = .unknown
    }
  }
}

public struct PreferencesGeneralSection: View {
  public let store: HarnessMonitorStore
  public let overview: PreferencesGeneralOverviewState
  @AppStorage(HarnessMonitorDateTimeConfiguration.timeZoneModeKey)
  private var timeZoneModeRawValue = HarnessMonitorDateTimeConfiguration.defaultTimeZoneModeRawValue
  @AppStorage(HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey)
  private var customTimeZoneIdentifier = HarnessMonitorDateTimeConfiguration
    .defaultCustomTimeZoneIdentifier
  @State private var isRemoveLaunchAgentConfirmationPresented = false

  public init(store: HarnessMonitorStore, overview: PreferencesGeneralOverviewState) {
    self.store = store
    self.overview = overview
  }

  private static let externalDaemonCommand = "harness daemon dev"

  @ViewBuilder private var daemonModeRow: some View {
    LabeledContent("Daemon mode") {
      VStack(alignment: .trailing, spacing: 2) {
        Text(overview.daemonModeLabel)
        if overview.isExternalDaemon {
          Text("Run `\(Self.externalDaemonCommand)` in a terminal")
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Daemon Mode"))
    if overview.isExternalDaemon {
      LabeledContent("Dev manifest") {
        Text(overview.externalDaemonManifestPath)
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .multilineTextAlignment(.trailing)
      }
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.preferencesMetricCard("Dev Manifest")
      )
      if let summary = overview.externalDaemonProcessSummary {
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

  public var body: some View {
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
        LabeledContent("Endpoint", value: overview.endpoint)
          .textSelection(.enabled)
          .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Endpoint"))
        LabeledContent("Version", value: overview.version)
          .textSelection(.enabled)
          .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Version"))
        daemonModeRow
        if overview.showsLaunchAgent {
          LabeledContent("Launchd") {
            VStack(alignment: .trailing, spacing: 2) {
              Text(overview.launchAgentState)
              Text(overview.launchAgentCaption)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Launchd"))
        }
        LabeledContent("Sandbox") {
          if overview.sandboxState == .enabled {
            Text("Enabled")
              .scaledFont(.caption)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(HarnessMonitorTheme.accent.opacity(0.18), in: Capsule())
              .foregroundStyle(HarnessMonitorTheme.accent)
          } else {
            Text(overview.sandboxState == .unknown ? "Unknown" : "Off")
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Sandbox"))
        LabeledContent("Database Size") {
          Text(overview.databaseSize)
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Database Size"))
        LabeledContent("Live Sessions") {
          Text("\(overview.sessionCount)")
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesMetricCard("Live Sessions"))
      } header: {
        Text("Overview")
      }

      PreferencesStatusSection(startedAt: overview.startedAt)
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

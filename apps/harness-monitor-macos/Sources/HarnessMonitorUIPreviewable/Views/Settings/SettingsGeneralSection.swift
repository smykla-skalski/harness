import HarnessMonitorKit
import SwiftUI

public struct SettingsGeneralOverviewState {
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

public struct SettingsGeneralSection: View {
  public let store: HarnessMonitorStore
  public let overview: SettingsGeneralOverviewState
  @AppStorage(HarnessMonitorDateTimeConfiguration.timeZoneModeKey)
  private var timeZoneModeRawValue = HarnessMonitorDateTimeConfiguration.defaultTimeZoneModeRawValue
  @AppStorage(HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey)
  private var customTimeZoneIdentifier = HarnessMonitorDateTimeConfiguration
    .defaultCustomTimeZoneIdentifier
  @AppStorage(SessionTimelineFilterDefaults.persistenceModeKey)
  private var timelineFilterPersistenceModeRawValue =
    SessionTimelineFilterDefaults.defaultPersistenceMode.rawValue
  @AppStorage(HarnessMonitorLaunchBehavior.storageKey)
  private var launchBehaviorRawValue = HarnessMonitorLaunchBehavior.defaultValue.rawValue
  @AppStorage(OpenRecentCloseAfterPickDefaults.storageKey)
  private var closeOpenRecentAfterPick = OpenRecentCloseAfterPickDefaults.defaultValue
  @AppStorage(SessionWindowTabbingPreference.storageKey)
  private var sessionWindowTabbingRawValue = SessionWindowTabbingPreference.defaultValue.rawValue
  @State private var isRemoveLaunchAgentConfirmationPresented = false

  public init(store: HarnessMonitorStore, overview: SettingsGeneralOverviewState) {
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
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMetricCard("Daemon Mode"))
    if overview.isExternalDaemon {
      LabeledContent("Dev manifest") {
        Text(overview.externalDaemonManifestPath)
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .multilineTextAlignment(.trailing)
      }
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsMetricCard("Dev Manifest")
      )
      if let summary = overview.externalDaemonProcessSummary {
        LabeledContent("Dev daemon") {
          Text(summary)
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsMetricCard("Dev Daemon")
        )
      }
    }
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

  private var launchBehavior: HarnessMonitorLaunchBehavior {
    HarnessMonitorLaunchBehavior.resolved(rawValue: launchBehaviorRawValue)
  }

  private var sessionWindowTabbingPreference: SessionWindowTabbingPreference {
    SessionWindowTabbingPreference.resolved(rawValue: sessionWindowTabbingRawValue)
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
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTimeZoneModePicker)

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
          .accessibilityIdentifier(HarnessMonitorAccessibility.settingsCustomTimeZonePicker)
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
          .accessibilityIdentifier("harness.settings.footer.datetime")
      }

      Section {
        Picker("Filter persistence", selection: $timelineFilterPersistenceModeRawValue) {
          ForEach(SessionTimelineFilterPersistenceMode.allCases) { mode in
            Text(mode.label).tag(mode.rawValue)
          }
        }
        .harnessNativeFormControl()
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsTimelinePersistencePicker
        )
      } header: {
        Text("Timeline")
      } footer: {
        Text(
          "Controls whether Session cockpit timeline filters reset each time, "
            + "restore per window and session, or reopen app-wide."
        )
      }

      Section {
        Picker("Launch behavior", selection: $launchBehaviorRawValue) {
          ForEach(HarnessMonitorLaunchBehavior.allCases) { behavior in
            Text(behavior.label).tag(behavior.rawValue)
          }
        }
        .harnessNativeFormControl()
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsLaunchBehaviorPicker)

        Toggle("Close Open Recent after picking a session", isOn: $closeOpenRecentAfterPick)
          .accessibilityLabel("Close Open Recent after picking a session")
          .accessibilityHint("When enabled, choosing a recent session closes the welcome window.")

        Picker("Session window tabs", selection: $sessionWindowTabbingRawValue) {
          ForEach(SessionWindowTabbingPreference.allCases) { preference in
            Text(preference.label).tag(preference.rawValue)
          }
        }
        .harnessNativeFormControl()
        .accessibilityLabel("Session window tabs")
        .accessibilityHint("Controls whether session windows prefer native macOS tabs.")
      } header: {
        Text("Windows")
      } footer: {
        Text("\(launchBehavior.description) \(sessionWindowTabbingPreference.description)")
      }

      SettingsLoggingSection(store: store)

      Section {
        SettingsActionButtons(
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
          .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMetricCard("Endpoint"))
        LabeledContent("Version", value: overview.version)
          .textSelection(.enabled)
          .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMetricCard("Version"))
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
          .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMetricCard("Launchd"))
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
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMetricCard("Sandbox"))
        LabeledContent("Database Size") {
          Text(overview.databaseSize)
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMetricCard("Database Size"))
        LabeledContent("Live Sessions") {
          Text("\(overview.sessionCount)")
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMetricCard("Live Sessions"))
      } header: {
        Text("Overview")
      }

      SettingsStatusSection(startedAt: overview.startedAt)
    }
    .settingsDetailFormStyle()
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

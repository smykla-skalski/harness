import HarnessMonitorKit
import SwiftUI

public struct PreferencesLoggingSection: View {
  public let store: HarnessMonitorStore
  @AppStorage(HarnessMonitorLoggerDefaults.supervisorLogLevelKey)
  private var supervisorLogLevel = HarnessMonitorLogger.defaultSupervisorLogLevel

  public init(store: HarnessMonitorStore) {
    self.store = store
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

  private var supervisorLogLevelBinding: Binding<String> {
    Binding(
      get: {
        HarnessMonitorLoggerDefaults.normalizedSupervisorLogLevel(
          supervisorLogLevel
        )
      },
      set: { newValue in
        let normalized = HarnessMonitorLoggerDefaults.normalizedSupervisorLogLevel(
          newValue
        )
        supervisorLogLevel = normalized
        HarnessMonitorLogger.syncSupervisorLogLevel(from: normalized)
      }
    )
  }

  public var body: some View {
    Section {
      Picker("Daemon log level", selection: daemonLogLevelBinding) {
        ForEach(Array(Self.logLevels.enumerated()), id: \.offset) { _, level in
          Text(level.uppercased()).tag(level)
        }
      }
      .harnessNativeFormControl()
      .disabled(store.connectionState != .online)
      .accessibilityHint(
        "Changes the daemon logging threshold until the daemon restarts"
      )
      .accessibilityIdentifier("harness.preferences.daemon.logLevel")

      Picker("Supervisor log level", selection: supervisorLogLevelBinding) {
        ForEach(Array(Self.logLevels.enumerated()), id: \.offset) { _, level in
          Text(level.uppercased()).tag(level)
        }
      }
      .harnessNativeFormControl()
      .accessibilityHint(
        "Changes app-local supervisor diagnostics and persists between launches"
      )
      .accessibilityIdentifier("harness.preferences.supervisor.logLevel")
    } header: {
      Text("Logging")
    } footer: {
      Text(
        "Daemon logging updates the running harness process and resets on daemon restart."
          + " Supervisor logging controls app-local diagnostics and persists between launches."
      )
      .accessibilityIdentifier("harness.preferences.footer.logging")
    }
  }
}

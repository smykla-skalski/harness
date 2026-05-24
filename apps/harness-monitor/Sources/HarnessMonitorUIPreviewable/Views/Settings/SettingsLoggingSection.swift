import HarnessMonitorKit
import SwiftUI

public struct SettingsLoggingSection: View {
  public let daemonLogLevel: String
  public let isDaemonOnline: Bool
  private let setDaemonLogLevel: @MainActor (String) -> Void
  @AppStorage(HarnessMonitorLoggerDefaults.supervisorLogLevelKey)
  private var supervisorLogLevel = HarnessMonitorLogger.defaultSupervisorLogLevel

  public init(
    daemonLogLevel: String,
    isDaemonOnline: Bool,
    setDaemonLogLevel: @escaping @MainActor (String) -> Void
  ) {
    self.daemonLogLevel = daemonLogLevel
    self.isDaemonOnline = isDaemonOnline
    self.setDaemonLogLevel = setDaemonLogLevel
  }

  private static let logLevels = ["trace", "debug", "info", "warn", "error"]

  private var daemonLogLevelBinding: Binding<String> {
    Binding(
      get: { daemonLogLevel },
      set: { newValue in
        setDaemonLogLevel(newValue)
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
      .disabled(!isDaemonOnline)
      .accessibilityHint(
        "Changes the daemon logging threshold and persists across daemon restarts"
      )
      .accessibilityIdentifier("harness.settings.daemon.logLevel")

      Picker("Supervisor log level", selection: supervisorLogLevelBinding) {
        ForEach(Array(Self.logLevels.enumerated()), id: \.offset) { _, level in
          Text(level.uppercased()).tag(level)
        }
      }
      .harnessNativeFormControl()
      .accessibilityHint(
        "Changes app-local supervisor diagnostics and persists between launches"
      )
      .accessibilityIdentifier("harness.settings.supervisor.logLevel")
    } header: {
      Text("Logging")
    } footer: {
      Text(
        "Daemon logging updates the running harness process and persists across daemon restarts"
          + " Supervisor logging controls app-local diagnostics and persists between launches"
      )
      .accessibilityIdentifier("harness.settings.footer.logging")
    }
  }
}

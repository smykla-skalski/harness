import HarnessMonitorKit
import SwiftUI

struct PreferencesDiagnosticsOverview: View {
  let launchAgent: LaunchAgentStatus?
  let tokenPresent: Bool
  let projectCount: Int
  let worktreeCount: Int
  let sessionCount: Int
  let lastEvent: DaemonAuditEvent?
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    Section("Overview") {
      LabeledContent("Token") {
        Label(
          tokenPresent ? "Present" : "Missing",
          systemImage: tokenPresent ? "checkmark.circle.fill" : "xmark.circle.fill"
        )
        .foregroundStyle(tokenPresent ? HarnessMonitorTheme.success : HarnessMonitorTheme.danger)
      }
      LabeledContent("Projects", value: "\(projectCount)")
      LabeledContent("Worktrees", value: "\(worktreeCount)")
      LabeledContent("Sessions", value: "\(sessionCount)")
    }

    if let launchAgent {
      Section("Launch Agent") {
        LabeledContent("Status") {
          Text(launchAgent.lifecycleTitle)
            .foregroundStyle(
              launchAgent.pid == nil
                ? HarnessMonitorTheme.ink : HarnessMonitorTheme.success
            )
        }
        if !launchAgent.lifecycleCaption.isEmpty {
          Text(launchAgent.lifecycleCaption)
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }

    if let lastEvent {
      Section("Latest Event") {
        LabeledContent("Level") {
          Text(lastEvent.level.uppercased())
            .tracking(HarnessMonitorTheme.uppercaseTracking)
        }
        Text(lastEvent.message)
        Text(formatTimestamp(lastEvent.recordedAt, configuration: dateTimeConfiguration))
          .scaledFont(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
    }
  }
}

#Preview("Preferences Diagnostics Overview") {
  let store = PreferencesPreviewSupport.makeStore()

  Form {
    PreferencesDiagnosticsOverview(
      launchAgent: store.daemonStatus?.launchAgent,
      tokenPresent: store.diagnostics?.workspace.authTokenPresent ?? false,
      projectCount: store.daemonStatus?.projectCount ?? 0,
      worktreeCount: store.daemonStatus?.worktreeCount ?? 0,
      sessionCount: store.daemonStatus?.sessionCount ?? 0,
      lastEvent: store.diagnostics?.workspace.lastEvent
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 560)
}

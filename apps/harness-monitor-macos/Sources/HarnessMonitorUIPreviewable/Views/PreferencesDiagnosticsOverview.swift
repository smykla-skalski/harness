import HarnessMonitorKit
import SwiftUI

struct PreferencesDiagnosticsOverview: View {
  let launchAgent: LaunchAgentStatus?
  let tokenPresent: Bool
  let projectCount: Int
  let worktreeCount: Int
  let sessionCount: Int
  let externalSessionCount: Int
  let lastExternalSessionAttachOutcome: String?
  let lastExternalSessionAttachSucceeded: Bool?
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
      LabeledContent("External Sessions") {
        VStack(alignment: .trailing, spacing: HarnessMonitorTheme.itemSpacing) {
          Text("\(externalSessionCount) attached")
          if let lastExternalSessionAttachOutcome,
            let lastExternalSessionAttachSucceeded
          {
            Label(
              lastExternalSessionAttachOutcome,
              systemImage: lastExternalSessionAttachSucceeded
                ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .labelStyle(.titleAndIcon)
            .scaledFont(.caption)
            .foregroundStyle(
              lastExternalSessionAttachSucceeded
                ? HarnessMonitorTheme.success : HarnessMonitorTheme.danger
            )
            .multilineTextAlignment(.trailing)
          } else {
            Text("No attach attempts yet")
              .scaledFont(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
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
        LabeledContent("Recorded At") {
          Text(formatTimestamp(lastEvent.recordedAt, configuration: dateTimeConfiguration))
            .scaledFont(.caption.monospaced())
        }
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
      externalSessionCount: store.sessions.filter { $0.externalOrigin != nil }.count,
      lastExternalSessionAttachOutcome: store.lastExternalSessionAttachOutcome?.message,
      lastExternalSessionAttachSucceeded: store.lastExternalSessionAttachOutcome?.succeeded,
      lastEvent: store.diagnostics?.workspace.lastEvent
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 560)
}

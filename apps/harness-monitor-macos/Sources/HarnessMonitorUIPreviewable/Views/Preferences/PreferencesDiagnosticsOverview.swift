import HarnessMonitorKit
import SwiftUI

struct PreferencesDiagnosticsOverview: View {
  let launchAgent: LaunchAgentStatus?
  let mcpStatus: HarnessMonitorMCPStatusSnapshot
  let tokenPresent: Bool
  let projectCount: Int
  let worktreeCount: Int
  let sessionCount: Int
  let externalSessionCount: Int
  let lastExternalSessionAttachOutcome: String?
  let lastExternalSessionAttachSucceeded: Bool?
  let lastEvent: DaemonAuditEvent?
  let repairLaunchAgent: (() async -> Void)?
  @State private var isRepairInFlight = false
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
        if let repairLaunchAgent {
          LabeledContent("Repair") {
            Button {
              guard !isRepairInFlight else { return }
              isRepairInFlight = true
              Task {
                await repairLaunchAgent()
                isRepairInFlight = false
              }
            } label: {
              Text(isRepairInFlight ? "Repairing…" : "Repair Launch Agent Registration")
            }
            .disabled(isRepairInFlight)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.preferencesLaunchAgentRepairButton
            )
          }
          Text(
            "In managed mode, unregisters then re-registers the SMAppService "
              + "launch agent. In external mode, only unregisters to clean up "
              + "an orphan registration. Use this to recover from xpcproxy "
              + "spawn-fail loops (EX_CONFIG / stale BTM uuid). Watch the Status "
              + "row above for the new PID after the action completes; it also "
              + "reloads the plist so daemon stderr starts landing in "
              + "~/Library/Logs/io.harnessmonitor.daemon.stderr.log."
          )
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }

    Section("MCP") {
      LabeledContent("Status") {
        MCPStatusLabel(status: mcpStatus, variant: .detail)
      }
      Text(mcpStatus.detail)
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
      if let recoverySummary = mcpStatus.recoverySummary {
        Text(recoverySummary)
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
      }
      if let socketPath = mcpStatus.socketPath {
        LabeledContent("Socket") {
          Text(socketPath)
            .scaledFont(.caption.monospaced())
            .textSelection(.enabled)
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

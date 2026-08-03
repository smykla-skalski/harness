import HarnessMonitorKit
import SwiftUI

struct DashboardCodexStatusCard: View {
  let detail: DashboardCodexAgentDetail

  var body: some View {
    DashboardAcpSection(title: "Runtime and continuity") {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
        fact("Status", detail.run?.status.title ?? "Unavailable")
        fact("Continuity", detail.continuity.title)
        fact("Evidence", detail.continuity.detail)
        fact("Mode", detail.run?.mode.title ?? "Unavailable")
        fact("Attachment", detail.inspect?.attached == true ? "Attached" : "Not attached")
        fact("Thread", detail.run?.threadId ?? "Not assigned")
        fact("Turn", detail.run?.turnId ?? "Not assigned")
        fact("Model", detail.run?.model ?? "Daemon default")
        fact("Effort", detail.run?.effort?.capitalized ?? "Daemon default")
        fact("Events", String(detail.run?.events.count ?? 0))
      }
    }
  }

  private func fact(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
      Text(value.withoutTrailingPeriod)
        .textSelection(.enabled)
        .gridColumnAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scaledFont(.callout)
  }
}

struct DashboardCodexApprovals: View {
  let approvals: [CodexApprovalRequest]
  let isBusy: Bool
  let onResolve: (CodexApprovalRequest, CodexApprovalDecision) -> Void

  var body: some View {
    if approvals.isEmpty {
      DashboardAcpSection(title: "Approvals") {
        Label("No approval requests are pending", systemImage: "checkmark.shield")
          .foregroundStyle(.secondary)
      }
    } else {
      ForEach(approvals) { approval in
        DashboardAcpSection(title: approval.title.withoutTrailingPeriod) {
          Text("This request remains pending until the daemon accepts a resolution")
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
          if !approval.detail.isEmpty {
            Text(approval.detail.withoutTrailingPeriod).textSelection(.enabled)
          }
          if let command = approval.command {
            Text(command.withoutTrailingPeriod)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
          }
          HStack {
            Spacer()
            ForEach(CodexApprovalDecision.allCases, id: \.self) { decision in
              Button(decision.title, role: decision.isDestructive ? .destructive : nil) {
                onResolve(approval, decision)
              }
              .disabled(isBusy)
            }
          }
        }
      }
    }
  }
}

struct DashboardCodexActivity: View {
  let events: [CodexRunEvent]

  var body: some View {
    DashboardAcpSection(title: "Activity") {
      if events.isEmpty {
        Text("No activity events are available for this managed agent")
          .foregroundStyle(.secondary)
      } else {
        ForEach(events.suffix(30)) { event in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(event.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                .scaledFont(.caption.weight(.medium))
              Spacer()
              Text("#\(event.sequence)")
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
            }
            Text(event.summary.withoutTrailingPeriod).textSelection(.enabled)
          }
          .padding(.vertical, 5)
        }
      }
    }
  }
}

extension CodexApprovalDecision {
  fileprivate var title: String {
    switch self {
    case .accept: "Accept"
    case .acceptForSession: "Accept for session"
    case .decline: "Decline"
    case .cancel: "Cancel"
    }
  }

  fileprivate var isDestructive: Bool {
    self == .decline || self == .cancel
  }
}

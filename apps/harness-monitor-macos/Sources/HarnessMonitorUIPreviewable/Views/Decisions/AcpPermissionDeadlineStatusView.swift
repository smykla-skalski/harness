import HarnessMonitorKit
import SwiftUI

@MainActor
struct AcpPermissionDeadlineStatusView: View {
  enum Style {
    case row
    case detail
  }

  let payload: AcpPermissionDecisionPayload
  let lastMessageAt: Date?
  let style: Style
  let accessibilityIdentifier: String?
  let referenceDate: Date?

  var body: some View {
    if let referenceDate {
      if let status = payload.deadlineStatus(
        now: referenceDate,
        lastMessageAt: lastMessageAt
      ) {
        identifiedStatusLabel(status)
      }
    } else if payload.expiresAtDate != nil {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        if let status = payload.deadlineStatus(
          now: context.date,
          lastMessageAt: lastMessageAt
        ) {
          identifiedStatusLabel(status)
        }
      }
    }
  }

  @ViewBuilder
  private func identifiedStatusLabel(
    _ status: AcpPermissionDeadlineStatus
  ) -> some View {
    let label = statusLabel(status)
      .accessibilityValue(status.accessibilityValue)
    if let accessibilityIdentifier {
      label.accessibilityIdentifier(accessibilityIdentifier)
    } else {
      label
    }
  }

  @ViewBuilder
  private func statusLabel(
    _ status: AcpPermissionDeadlineStatus
  ) -> some View {
    let tint = statusTint(for: status.phase)
    let content = HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: status.symbolName)
        .imageScale(.small)
      Text(status.label)
        .monospacedDigit()
    }
    .foregroundStyle(tint)

    switch style {
    case .row:
      content
        .scaledFont(.caption.bold())
    case .detail:
      content
        .scaledFont(.callout.bold())
        .padding(.horizontal, HarnessMonitorTheme.spacingSM)
        .padding(.vertical, HarnessMonitorTheme.spacingXS)
        .background {
          Capsule(style: .continuous)
            .fill(tint.opacity(0.12))
        }
        .overlay {
          Capsule(style: .continuous)
            .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
    }
  }

  private func statusTint(
    for phase: AcpPermissionDeadlinePhase
  ) -> Color {
    switch phase {
    case .pending:
      HarnessMonitorTheme.secondaryInk
    case .expiring, .stale:
      HarnessMonitorTheme.caution
    case .expired:
      HarnessMonitorTheme.danger
    }
  }
}

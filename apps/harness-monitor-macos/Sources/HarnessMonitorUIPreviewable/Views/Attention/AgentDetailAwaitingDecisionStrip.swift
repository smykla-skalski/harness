import HarnessMonitorKit
import SwiftUI

struct AgentDetailAwaitingDecisionStrip: View {
  let payload: AcpPermissionDecisionPayload?
  let count: Int
  let isResolving: Bool
  let approveButtonAccessibilityIdentifier: String
  let denyButtonAccessibilityIdentifier: String
  let viewAllButtonAccessibilityIdentifier: String
  let onApprove: () -> Void
  let onDeny: () -> Void
  let onViewAll: () -> Void

  private var canActInline: Bool {
    payload?.isRenderable == true && !isResolving
  }

  private var topRequestTitle: String? {
    payload?.renderableBatch?.requests.first?.title
  }

  private var topRequestBreadcrumb: String? {
    payload?.renderableBatch?.requests.first?.breadcrumb
  }

  private var eyebrow: String {
    if let agentName = payload?.agent.agentName, topRequestTitle != nil {
      return "Pending permission · \(agentName)"
    }
    return "Pending permission"
  }

  private var headline: String {
    topRequestTitle ?? "Agent awaiting your decision"
  }

  private var supplementarySubtitle: String? {
    if isResolving {
      return "Submitting decision..."
    }
    if payload != nil && payload?.isRenderable != true {
      return "Request details unavailable here — review in Decisions to inspect and act."
    }
    if count > 1 {
      if topRequestTitle != nil {
        return count == 2 ? "+1 more pending" : "+\(count - 1) more pending"
      }
      return "\(count) requests waiting"
    }
    return topRequestBreadcrumb
  }

  private var approveLabel: String {
    count > 1 ? "Approve all" : "Approve"
  }

  private var denyLabel: String {
    count > 1 ? "Deny all" : "Deny"
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
      Image(systemName: "person.badge.shield.checkmark")
        .scaledFont(.title3.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.caution)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text(eyebrow)
          .scaledFont(.caption2.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .textCase(.uppercase)
        Text(headline)
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
          .fixedSize(horizontal: false, vertical: true)
        if let supplementarySubtitle {
          Text(supplementarySubtitle)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
        actionsRow
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      HarnessMonitorBadge(value: count.formatted())
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.caution.opacity(0.12))
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .stroke(HarnessMonitorTheme.caution.opacity(0.35), lineWidth: 1)
    }
  }

  @ViewBuilder
  private var actionsRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      if canActInline {
        Button(approveLabel, action: onApprove)
          .harnessActionButtonStyle(variant: .prominent, tint: nil)
          .controlSize(HarnessMonitorControlMetrics.compactControlSize)
          .accessibilityIdentifier(approveButtonAccessibilityIdentifier)
          .accessibilityAddTraits(.isButton)
        Button(denyLabel, action: onDeny)
          .harnessActionButtonStyle(variant: .bordered, tint: .red)
          .controlSize(HarnessMonitorControlMetrics.compactControlSize)
          .accessibilityIdentifier(denyButtonAccessibilityIdentifier)
          .accessibilityAddTraits(.isButton)
        if count > 1 {
          Button("Review individually", action: onViewAll)
            .harnessActionButtonStyle(variant: .bordered, tint: nil)
            .controlSize(HarnessMonitorControlMetrics.compactControlSize)
            .accessibilityIdentifier(viewAllButtonAccessibilityIdentifier)
            .accessibilityAddTraits(.isButton)
        }
      } else {
        Button("Open in Decisions", action: onViewAll)
          .harnessActionButtonStyle(variant: .bordered, tint: nil)
          .controlSize(HarnessMonitorControlMetrics.compactControlSize)
          .accessibilityIdentifier(viewAllButtonAccessibilityIdentifier)
          .accessibilityAddTraits(.isButton)
      }
    }
    .padding(.top, HarnessMonitorTheme.spacingXS)
  }
}

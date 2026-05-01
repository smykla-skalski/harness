import HarnessMonitorKit
import SwiftUI

/// Single row in the Decisions sidebar. Keep the first line focused on the decision itself and
/// the second line on quieter scope metadata so operators can scan the queue quickly.
struct DecisionRow: View {
  let decision: Decision
  let isSelected: Bool
  let fontScale: CGFloat
  let acpPayload: AcpPermissionDecisionPayload?
  let lastMessageAt: Date?
  let select: () -> Void

  init(
    decision: Decision,
    isSelected: Bool,
    fontScale: CGFloat,
    acpPayload: AcpPermissionDecisionPayload? = nil,
    lastMessageAt: Date? = nil,
    select: @escaping () -> Void
  ) {
    self.decision = decision
    self.isSelected = isSelected
    self.fontScale = fontScale
    self.acpPayload = acpPayload
    self.lastMessageAt = lastMessageAt
    self.select = select
  }

  @MainActor private static let ageFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  private var severity: DecisionSeverity {
    DecisionSeverity(rawValue: decision.severityRaw) ?? .info
  }

  private var age: String {
    let interval = Date.now.timeIntervalSince(decision.createdAt)
    return Self.ageFormatter.localizedString(fromTimeInterval: -interval)
  }

  private var metaLine: String {
    var parts: [String] = [severity.chipLabel]
    if let agentID = decision.agentID, !agentID.isEmpty {
      parts.append(humanizedWorkspaceLabel(agentID))
    }
    if let taskID = decision.taskID, !taskID.isEmpty {
      parts.append(humanizedWorkspaceLabel(taskID))
    } else if let sessionID = decision.sessionID, !sessionID.isEmpty {
      parts.append(humanizedWorkspaceLabel(sessionID))
    }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder var body: some View {
    if acpPayload?.expiresAtDate != nil {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        rowButton(referenceDate: context.date)
      }
    } else {
      rowButton(referenceDate: .now)
    }
  }

  private func rowButton(
    referenceDate: Date
  ) -> some View {
    let deadlineStatus = acpPayload?.deadlineStatus(
      now: referenceDate,
      lastMessageAt: lastMessageAt
    )

    return Button(action: select) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        Circle()
          .fill(severity.chipColor)
          .frame(width: 8, height: 8)
          .padding(.top, 6)
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXS) {
            Text(decision.summary)
              .scaledFont(.callout.weight(isSelected ? .semibold : .regular))
              .lineLimit(2)
              .multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(age)
              .scaledFont(.caption.monospacedDigit())
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(1)
          }
          Text(metaLine)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(2)
          if let acpPayload {
            AcpPermissionDeadlineStatusView(
              payload: acpPayload,
              lastMessageAt: lastMessageAt,
              style: .row,
              accessibilityIdentifier: HarnessMonitorAccessibility.decisionDeadline(decision.id),
              referenceDate: referenceDate
            )
          }
        }
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM * fontScale)
      .background(
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
          .fill(isSelected ? HarnessMonitorTheme.accent.opacity(0.16) : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
          .strokeBorder(
            isSelected ? HarnessMonitorTheme.accent.opacity(0.28) : Color.clear,
            lineWidth: 1
          )
      )
    }
    .harnessInteractiveCardButtonStyle(
      cornerRadius: HarnessMonitorTheme.cornerRadiusSM,
      tint: isSelected ? HarnessMonitorTheme.accent : nil,
      extraHoverHint: isSelected
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabelText(deadlineStatus: deadlineStatus))
    .harnessMCPRow(
      HarnessMonitorAccessibility.decisionRow(decision.id),
      label: accessibilityLabelText(deadlineStatus: deadlineStatus),
      value: accessibilityValueText(deadlineStatus: deadlineStatus),
      pressAction: select
    )
  }

  private func accessibilityLabelText(
    deadlineStatus: AcpPermissionDeadlineStatus?
  ) -> String {
    var parts = ["\(severity.chipLabel). \(decision.summary). \(metaLine)"]
    if deadlineStatus != nil {
      parts.append("deadline shown below")
    }
    return parts.joined(separator: ". ")
  }

  private func accessibilityValueText(
    deadlineStatus: AcpPermissionDeadlineStatus?
  ) -> String {
    _ = deadlineStatus
    return isSelected ? "selected" : "not selected"
  }
}

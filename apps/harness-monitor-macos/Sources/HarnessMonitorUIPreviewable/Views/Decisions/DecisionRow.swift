import HarnessMonitorKit
import SwiftUI

/// Single row in the Decisions sidebar. Severity dot + summary (wrapped to two lines) + a
/// meta line showing agent, task, and relative age so operators can triage without opening
/// each decision. A fresh-pill appears for decisions under two minutes old.
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

  private static let freshWindow: TimeInterval = 120

  private var severity: DecisionSeverity {
    DecisionSeverity(rawValue: decision.severityRaw) ?? .info
  }

  private var age: String {
    let interval = Date.now.timeIntervalSince(decision.createdAt)
    return Self.ageFormatter.localizedString(fromTimeInterval: -interval)
  }

  private var isFresh: Bool {
    Date.now.timeIntervalSince(decision.createdAt) <= Self.freshWindow
  }

  private var metaLine: String {
    var parts: [String] = []
    if let agentID = decision.agentID, !agentID.isEmpty {
      parts.append(agentID)
    }
    if let taskID = decision.taskID, !taskID.isEmpty {
      parts.append(taskID)
    }
    parts.append(age)
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  var body: some View {
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
          HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingXS) {
            Text(decision.summary)
              .scaledFont(.body)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, alignment: .leading)
            if isFresh {
              freshPill
            }
          }
          Text(metaLine)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
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
      .contentShape(
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
      )
    }
    .harnessDismissButtonStyle()
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabelText(deadlineStatus: deadlineStatus))
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionRow(decision.id))
    .accessibilityValue(accessibilityValueText(deadlineStatus: deadlineStatus))
  }

  private func accessibilityLabelText(
    deadlineStatus: AcpPermissionDeadlineStatus?
  ) -> String {
    var parts = ["\(severity.chipLabel). \(decision.summary). \(metaLine)"]
    if let deadlineStatus {
      parts.append(deadlineStatus.label)
    }
    return parts.joined(separator: ". ")
  }

  private func accessibilityValueText(
    deadlineStatus: AcpPermissionDeadlineStatus?
  ) -> String {
    var parts = [isSelected ? "selected" : "not selected"]
    if let deadlineStatus {
      parts.append(deadlineStatus.accessibilityValue)
    }
    return parts.joined(separator: ", ")
  }

  private var freshPill: some View {
    Text("NEW")
      .scaledFont(.caption2.bold())
      .foregroundStyle(HarnessMonitorTheme.onContrast)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(
        Capsule().fill(severity.chipColor)
      )
  }
}

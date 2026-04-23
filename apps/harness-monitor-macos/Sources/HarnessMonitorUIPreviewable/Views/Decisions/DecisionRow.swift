import HarnessMonitorKit
import SwiftUI

/// Single row in the Decisions sidebar. Severity dot + summary (wrapped to two lines) + a
/// meta line showing agent, task, and relative age so operators can triage without opening
/// each decision. A fresh-pill appears for decisions under two minutes old.
struct DecisionRow: View {
  let decision: Decision
  let isSelected: Bool
  let fontScale: CGFloat
  let select: () -> Void

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

  var body: some View {
    Button(action: select) {
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
    .accessibilityLabel(
      "\(severity.chipLabel). \(decision.summary). \(metaLine)"
    )
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionRow(decision.id))
    .accessibilityValue(isSelected ? "selected" : "not selected")
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

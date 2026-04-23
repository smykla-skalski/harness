import HarnessMonitorKit
import SwiftUI

@MainActor
/// Audit-trail tab rendered inside the Decisions detail column.
public struct DecisionAuditTrailTab: View {
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  private let events: [SupervisorEvent]

  public init(events: [SupervisorEvent] = []) {
    self.events = events
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      if events.isEmpty {
        SidebarEmptyState(
          title: "No Audit Events",
          systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
          message: "Matching supervisor events will appear here as the decision evolves."
        )
      } else {
        ForEach(events, id: \.id) { event in
          AuditTrailEventRow(
            event: event,
            timestamp: formatTimestamp(event.createdAt, configuration: dateTimeConfiguration)
          )
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionAuditTrail)
  }
}

private struct AuditTrailEventRow: View {
  let event: SupervisorEvent
  let timestamp: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.itemSpacing) {
        Text(displayTitle(for: event.kind))
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        if let severity = eventSeverity {
          Text(severity.label)
            .scaledFont(.caption.bold())
            .foregroundStyle(severity.tint)
            .harnessPillPadding()
            .harnessControlPill(tint: severity.tint)
        }
        Text(timestamp)
          .scaledFont(.caption.monospacedDigit())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      if let ruleID = event.ruleID, !ruleID.isEmpty {
        Text(ruleID)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Text(formattedPayload(event.payloadJSON))
        .scaledFont(.callout.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
    .padding(HarnessMonitorTheme.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.04))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.32), lineWidth: 1)
    }
  }

  private var eventSeverity: (label: String, tint: Color)? {
    guard let severityRaw = event.severityRaw,
      let severity = DecisionSeverity(rawValue: severityRaw)
    else {
      return nil
    }
    switch severity {
    case .info:
      return ("Info", HarnessMonitorTheme.accent)
    case .warn:
      return ("Warning", HarnessMonitorTheme.caution)
    case .needsUser:
      return ("Needs User", HarnessMonitorTheme.warmAccent)
    case .critical:
      return ("Critical", HarnessMonitorTheme.danger)
    }
  }

  private func displayTitle(for kind: String) -> String {
    kind
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: ".", with: " ")
      .capitalized
  }

  private func formattedPayload(_ payloadJSON: String) -> String {
    guard let data = payloadJSON.data(using: .utf8) else {
      return payloadJSON
    }
    let object = try? JSONSerialization.jsonObject(with: data)
    guard JSONSerialization.isValidJSONObject(object as Any) else {
      return payloadJSON
    }
    guard
      let prettyData = try? JSONSerialization.data(
        withJSONObject: object as Any,
        options: [.prettyPrinted, .sortedKeys]
      ),
      let pretty = String(data: prettyData, encoding: .utf8)
    else {
      return payloadJSON
    }
    return pretty
  }
}

#Preview("Decision Audit Trail — empty") {
  DecisionAuditTrailTab()
    .frame(width: 420, height: 320)
}

#Preview("Decision Audit Trail — populated") {
  let first = SupervisorEvent(
    id: "evt-1",
    tickID: "tick-1",
    kind: "observe",
    ruleID: "stuck-agent",
    severity: nil,
    payloadJSON: "{\"summary\":\"rule observed idle gap\"}"
  )
  first.createdAt = Date(timeIntervalSince1970: 10)
  let second = SupervisorEvent(
    id: "evt-2",
    tickID: "tick-2",
    kind: "dispatch",
    ruleID: "stuck-agent",
    severity: .needsUser,
    payloadJSON: "{\"target\":{\"agentID\":\"agent-7\"},\"action\":\"queueDecision\"}"
  )
  second.createdAt = Date(timeIntervalSince1970: 20)

  return DecisionAuditTrailTab(events: [first, second])
    .frame(width: 420, height: 320)
}

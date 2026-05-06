import HarnessMonitorKit
import SwiftUI

/// Audit-trail tab rendered inside the Decisions detail column.
@MainActor
public struct DecisionAuditTrailTab: View {
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  private let events: [SupervisorEvent]

  public init(events: [SupervisorEvent] = []) {
    self.events = events
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      if events.isEmpty {
        emptyState
      } else {
        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
          AuditTrailTimelineRow(
            event: event,
            timestamp: formatTimestamp(event.createdAt, configuration: dateTimeConfiguration)
          )
          if index < events.count - 1 {
            Divider()
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionAuditTrail)
  }

  private var emptyState: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("No audit events yet")
          .scaledFont(.callout.weight(.semibold))
        Text("Changes to this decision appear here as the workspace responds.")
          .scaledFont(.footnote)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.04))
    }
  }
}

private struct AuditTrailTimelineRow: View {
  let event: SupervisorEvent
  let timestamp: String

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Circle()
        .fill(eventSeverity?.tint ?? HarnessMonitorTheme.controlBorder)
        .frame(width: 8, height: 8)
        .padding(.top, 6)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.itemSpacing) {
          Text(displayTitle(for: event.kind))
            .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
          Spacer(minLength: HarnessMonitorTheme.spacingSM)
          Text(timestamp)
            .scaledFont(.caption.monospacedDigit())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          if let severity = eventSeverity {
            Text(severity.label)
              .scaledFont(.caption.weight(.semibold))
              .foregroundStyle(severity.tint)
          }
          if let ruleID = event.ruleID, !ruleID.isEmpty {
            Text("Source · \(humanizedWorkspaceLabel(ruleID))")
              .scaledFont(.caption.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
        }
        if let summary = payloadSummary(event.payloadJSON) {
          Text(summary)
            .scaledFont(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let prettyPayload = formattedPayload(event.payloadJSON) {
          DisclosureGroup("Details") {
            Text(verbatim: prettyPayload)
              .scaledFont(.caption.monospaced())
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
              .padding(.top, HarnessMonitorTheme.spacingXS)
          }
          .scaledFont(.caption)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
    humanizedWorkspaceLabel(kind)
  }

  private func payloadSummary(_ payloadJSON: String) -> String? {
    guard let data = payloadJSON.data(using: .utf8) else {
      return nil
    }
    let object = try? JSONSerialization.jsonObject(with: data)
    return firstString(forKeys: ["summary", "message", "action", "mode"], in: object)
  }

  private func firstString(forKeys keys: [String], in object: Any?) -> String? {
    guard let object else {
      return nil
    }
    if let dictionary = object as? [String: Any] {
      for key in keys {
        if let value = dictionary[key] as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return value
        }
      }
      for value in dictionary.values {
        if let nested = firstString(forKeys: keys, in: value) {
          return nested
        }
      }
    } else if let array = object as? [Any] {
      for value in array {
        if let nested = firstString(forKeys: keys, in: value) {
          return nested
        }
      }
    }
    return nil
  }

  private func formattedPayload(_ payloadJSON: String) -> String? {
    let trimmed = payloadJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "{}", trimmed != "[]" else {
      return nil
    }
    guard let data = payloadJSON.data(using: .utf8) else {
      return trimmed
    }
    let object = try? JSONSerialization.jsonObject(with: data)
    guard JSONSerialization.isValidJSONObject(object as Any) else {
      return trimmed
    }
    guard
      let prettyData = try? JSONSerialization.data(
        withJSONObject: object as Any,
        options: [.prettyPrinted, .sortedKeys]
      ),
      let pretty = String(data: prettyData, encoding: .utf8)
    else {
      return trimmed
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

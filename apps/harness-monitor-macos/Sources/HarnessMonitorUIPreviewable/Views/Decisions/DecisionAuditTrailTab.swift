import HarnessMonitorKit
import SwiftUI

/// Audit-trail tab rendered inside the Decisions detail column.
@MainActor
public struct DecisionAuditTrailTab: View {
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  private let events: [SupervisorEvent]
  private let payloadPresentations: [String: DecisionAuditTrailPayloadPresentation]

  public init(events: [SupervisorEvent] = []) {
    self.init(events: events, payloadPresentations: [:])
  }

  init(
    events: [SupervisorEvent],
    payloadPresentations: [String: DecisionAuditTrailPayloadPresentation]
  ) {
    self.events = events
    self.payloadPresentations = payloadPresentations
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      if events.isEmpty {
        emptyState
      } else {
        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
          AuditTrailTimelineRow(
            event: event,
            payloadPresentation: payloadPresentation(for: event),
            timestamp: formatTimestamp(event.createdAt, configuration: dateTimeConfiguration)
          )
          .equatable()
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

  private func payloadPresentation(
    for event: SupervisorEvent
  ) -> DecisionAuditTrailPayloadPresentation {
    payloadPresentations[event.id]
      ?? DecisionAuditTrailPayloadPresentation(payloadJSON: event.payloadJSON)
  }
}

private struct AuditTrailTimelineRow: View {
  let event: SupervisorEvent
  let payloadPresentation: DecisionAuditTrailPayloadPresentation
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
        if let summary = payloadPresentation.summary {
          Text(summary)
            .scaledFont(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let payloadDetails = payloadPresentation.details {
          DisclosureGroup("Details") {
            payloadDetailsView(for: payloadDetails)
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

  @ViewBuilder
  private func payloadDetailsView(
    for payloadDetails: DecisionAuditTrailPayloadDetails
  ) -> some View {
    switch payloadDetails {
    case .json(let payloadPresentation):
      HarnessMonitorJSONCodeBlock(
        presentation: payloadPresentation,
        chrome: .plain,
        wrapLongLines: true
      )
      .padding(.top, HarnessMonitorTheme.spacingXS)
    case .raw(let rawPayload):
      Text(verbatim: rawPayload)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .padding(.top, HarnessMonitorTheme.spacingXS)
    }
  }
}

enum DecisionAuditTrailPayloadDetails: Equatable {
  case json(HarnessMonitorJSONPresentation)
  case raw(String)
}

struct DecisionAuditTrailPayloadPresentation: Equatable {
  let summary: String?
  let details: DecisionAuditTrailPayloadDetails?

  init(payloadJSON: String, decoder: JSONDecoder = JSONDecoder()) {
    let trimmed = payloadJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "{}", trimmed != "[]" else {
      summary = nil
      details = nil
      return
    }

    guard let data = trimmed.data(using: .utf8),
      let jsonValue = try? decoder.decode(JSONValue.self, from: data)
    else {
      summary = nil
      details = .raw(trimmed)
      return
    }

    summary = Self.firstString(
      forKeys: ["summary", "message", "action", "mode"],
      in: jsonValue
    )
    details = .json(.formatted(jsonValue: jsonValue))
  }

  private static func firstString(
    forKeys keys: [String],
    in value: JSONValue
  ) -> String? {
    switch value {
    case .object(let dictionary):
      for key in keys {
        guard case .string(let candidate)? = dictionary[key] else {
          continue
        }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return candidate
        }
      }
      for nestedValue in dictionary.values {
        if let nested = firstString(forKeys: keys, in: nestedValue) {
          return nested
        }
      }
    case .array(let values):
      for nestedValue in values {
        if let nested = firstString(forKeys: keys, in: nestedValue) {
          return nested
        }
      }
    case .bool, .null, .number, .string:
      return nil
    }

    return nil
  }
}

// MainActor isolation matches the implicit @MainActor on body; required
// because Self conforms to View which is MainActor-isolated.
extension AuditTrailTimelineRow: @MainActor Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.event == rhs.event && lhs.timestamp == rhs.timestamp
  }
}

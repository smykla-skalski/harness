import Foundation
import HarnessMonitorKit
import SwiftUI

/// Cached ISO8601 formatter for the audit detail header. Allocated once at
/// module scope so the detail view does not allocate a fresh formatter per
/// body invalidation.
@MainActor private let auditDetailAbsoluteTimestampFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()

/// Cached decoder used to detect a decision reference inside an
/// `actionDispatched` payload. Decoding happens once in `init` of
/// `AuditTimelineDetailView`, so the decoder must not allocate per body.
private let auditDetailDecisionReferenceDecoder = JSONDecoder()

/// Right-side detail pane for the Supervisor Audit Timeline.
///
/// Renders the header (kind badge, severity chip, absolute timestamp, rule ID
/// label) above an embedded `AuditTimelinePayloadInspectorView`. When the
/// event kind is `actionDispatched` and the payload encodes a queueDecision
/// reference, the footer offers an "Open decision" affordance. The action is
/// a stub for now; the coordinator wires the route to the live decisions
/// store after the unit lands.
@MainActor
public struct AuditTimelineDetailView: View {
  private let event: SupervisorEventSnapshot
  private let absoluteTimestamp: String
  private let severityDescriptor: AuditEventSeverityDescriptor?
  private let decisionReferenceID: String?
  private let onOpenDecision: (@MainActor (String) -> Void)?

  public init(
    event: SupervisorEventSnapshot,
    onOpenDecision: (@MainActor (String) -> Void)? = nil
  ) {
    self.event = event
    absoluteTimestamp = auditDetailAbsoluteTimestampFormatter.string(from: event.createdAt)
    severityDescriptor = AuditEventSeverityDescriptor(rawValue: event.severityRaw)
    decisionReferenceID = Self.decisionReferenceID(in: event)
    self.onOpenDecision = onOpenDecision
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      header
      Divider()
      payload
      if let decisionReferenceID, !decisionReferenceID.isEmpty,
        event.kind == "actionDispatched"
      {
        Divider()
        footer(decisionReferenceID: decisionReferenceID)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(HarnessMonitorTheme.spacingLG)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.03))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.audit.detail")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        AuditDetailKindBadge(kind: event.kind)
        if let descriptor = severityDescriptor {
          AuditDetailSeverityChip(descriptor: descriptor)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Text(absoluteTimestamp)
          .scaledFont(.caption.monospacedDigit())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityLabel(Text("Recorded at \(absoluteTimestamp)"))
      }
      if let ruleID = event.ruleID, !ruleID.isEmpty {
        Text("Rule \(humanizedWorkspaceLabel(ruleID))")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
  }

  private var payload: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Payload")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      AuditTimelinePayloadInspectorView(payloadJSON: event.payloadJSON)
    }
  }

  private func footer(decisionReferenceID: String) -> some View {
    HStack {
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button {
        onOpenDecision?(decisionReferenceID)
      } label: {
        Label("Open decision", systemImage: "arrow.up.right.square")
      }
      .buttonStyle(.borderless)
      .disabled(onOpenDecision == nil)
      .accessibilityIdentifier("harness.audit.detail.open-decision")
      .accessibilityLabel(Text("Open decision"))
      .accessibilityHint(Text("Reveals the decision referenced by this dispatched action"))
    }
  }

  /// Inspect the encoded `SupervisorAction` payload looking for a `queueDecision`
  /// variant. The Codable representation puts the case name as the outer key
  /// with its payload as the value, so `{"queueDecision":{"id":...}}` is the
  /// shape we test against. Returns `nil` for non-dispatched events or when
  /// the payload does not encode a decision reference.
  private static func decisionReferenceID(in event: SupervisorEventSnapshot) -> String? {
    guard event.kind == "actionDispatched",
      let data = event.payloadJSON.data(using: .utf8),
      let decoded = try? auditDetailDecisionReferenceDecoder.decode(JSONValue.self, from: data)
    else {
      return nil
    }
    guard case .object(let topLevel) = decoded,
      case .object(let queueDecision)? = topLevel["queueDecision"],
      case .string(let identifier)? = queueDecision["id"]
    else {
      return nil
    }
    let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

// MARK: - Header components

struct AuditEventSeverityDescriptor: Sendable {
  let label: String
  let tint: Color

  init?(rawValue: String?) {
    guard let rawValue, let severity = DecisionSeverity(rawValue: rawValue) else {
      return nil
    }
    switch severity {
    case .info:
      label = "Info"
      tint = HarnessMonitorTheme.accent
    case .warn:
      label = "Warning"
      tint = HarnessMonitorTheme.caution
    case .needsUser:
      label = "Needs User"
      tint = HarnessMonitorTheme.warmAccent
    case .critical:
      label = "Critical"
      tint = HarnessMonitorTheme.danger
    }
  }
}

private struct AuditDetailKindBadge: View {
  let kind: String

  var body: some View {
    Text(humanizedWorkspaceLabel(kind))
      .scaledFont(.caption.weight(.semibold))
      .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
      .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
      .background {
        Capsule(style: .continuous)
          .fill(HarnessMonitorTheme.ink.opacity(0.08))
      }
      .accessibilityLabel(Text("Kind \(kind)"))
  }
}

private struct AuditDetailSeverityChip: View {
  let descriptor: AuditEventSeverityDescriptor

  var body: some View {
    Text(descriptor.label)
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(descriptor.tint)
      .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
      .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
      .background {
        Capsule(style: .continuous)
          .fill(descriptor.tint.opacity(0.12))
      }
      .accessibilityLabel(Text("Severity \(descriptor.label)"))
  }
}

import HarnessMonitorKit
import SwiftUI

/// Single row in the Supervisor audit timeline. Mirrors the density of
/// `TaskBoardDecisionRow`: kind glyph + severity chip in the header, single
/// line of relative time, redacted one-line payload preview underneath.
struct AuditTimelineRow: View {
  let event: SupervisorEventSnapshot
  let isSelected: Bool

  init(event: SupervisorEventSnapshot, isSelected: Bool) {
    self.event = event
    self.isSelected = isSelected
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      kindBadge
      VStack(alignment: .leading, spacing: 2) {
        headerLine
        summaryLine
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .background(rowBackground)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(HarnessMonitorAccessibility.auditTimelineRow(event.id))
  }

  private var kindBadge: some View {
    Image(systemName: kind.systemImage)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(kind.tint)
      .frame(width: 20, height: 20)
      .background(
        Circle()
          .fill(kind.tint.opacity(0.16))
      )
      .accessibilityHidden(true)
  }

  private var headerLine: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Text(kind.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(1)
      severityChip
      Spacer(minLength: 0)
      // Re-render once a minute so the relative-time string ages with the wall
      // clock; AuditTimelineRow is Equatable on (event, isSelected), so without
      // a periodic TimelineView the displayed string would freeze.
      TimelineView(.periodic(from: .now, by: 60)) { context in
        Text(relativeTime(now: context.date))
          .scaledFont(.caption2)
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
          .lineLimit(1)
      }
    }
  }

  private var summaryLine: some View {
    Text(summary)
      .scaledFont(.caption)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .lineLimit(1)
      .truncationMode(.tail)
  }

  @ViewBuilder
  private var severityChip: some View {
    if let severity {
      Text(severity.chipLabel)
        .scaledFont(.caption2.weight(.semibold))
        .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
        .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
        .background(
          Capsule().fill(severity.chipColor.opacity(0.16))
        )
        .foregroundStyle(severity.chipColor)
        .accessibilityHidden(true)
    }
  }

  private var rowBackground: some View {
    RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(isSelected ? HarnessMonitorTheme.accent.opacity(0.14) : Color.clear)
  }

  private var kind: AuditTimelineRowKind {
    AuditTimelineRowKind(rawValue: event.kind) ?? .unknown
  }

  private var severity: DecisionSeverity? {
    guard let raw = event.severityRaw else { return nil }
    return DecisionSeverity(rawValue: raw)
  }

  private func relativeTime(now: Date) -> String {
    auditTimelineRelativeFormatter.localizedString(for: event.createdAt, relativeTo: now)
  }

  private var summary: String {
    let redacted = redactSupervisorPayloadJSON(event.payloadJSON)
    let collapsed = redacted
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if collapsed.isEmpty {
      return event.ruleID ?? "No payload"
    }
    if collapsed.count <= 80 {
      return collapsed
    }
    return String(collapsed.prefix(80)) + "…"
  }

  private var accessibilityLabel: String {
    var pieces: [String] = [kind.title]
    if let severity {
      pieces.append("\(severity.chipLabel) severity")
    }
    if let ruleID = event.ruleID, !ruleID.isEmpty {
      pieces.append("rule \(ruleID)")
    }
    pieces.append(auditTimelineAbsoluteFormatter.string(from: event.createdAt))
    return pieces.joined(separator: ", ")
  }
}

extension AuditTimelineRow: @MainActor Equatable {
  static func == (lhs: AuditTimelineRow, rhs: AuditTimelineRow) -> Bool {
    lhs.event == rhs.event && lhs.isSelected == rhs.isSelected
  }
}

/// Presentation envelope for the four audit kinds. Falls back to a neutral
/// "unknown" case so unrecognised future kinds still render rather than
/// disappearing.
enum AuditTimelineRowKind: String, Hashable, Sendable {
  case actionDispatched
  case actionExecuted
  case actionFailed
  case actionSuppressed
  case unknown

  var title: String {
    switch self {
    case .actionDispatched: "Dispatched"
    case .actionExecuted: "Executed"
    case .actionFailed: "Failed"
    case .actionSuppressed: "Suppressed"
    case .unknown: "Event"
    }
  }

  var systemImage: String {
    switch self {
    case .actionDispatched: "paperplane.fill"
    case .actionExecuted: "checkmark.circle.fill"
    case .actionFailed: "exclamationmark.octagon.fill"
    case .actionSuppressed: "moon.zzz.fill"
    case .unknown: "circle.dotted"
    }
  }

  var tint: Color {
    switch self {
    case .actionDispatched: HarnessMonitorTheme.accent
    case .actionExecuted: HarnessMonitorTheme.accent
    case .actionFailed: HarnessMonitorTheme.danger
    case .actionSuppressed: HarnessMonitorTheme.caution
    case .unknown: HarnessMonitorTheme.tertiaryInk
    }
  }
}

extension HarnessMonitorAccessibility {
  public static let auditTimelineList = "harness.supervisor.audit.timeline"
  public static let auditTimelineLoadOlder = "harness.supervisor.audit.timeline.load-older"
  public static let auditTimelineEmptyState = "harness.supervisor.audit.timeline.empty"

  public static func auditTimelineRow(_ id: String) -> String {
    "harness.supervisor.audit.timeline.row.\(slug(id))"
  }
}

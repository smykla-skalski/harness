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
    } else if let expiresAt = payload.expiresAtDate,
      AcpPermissionDeadlineTimelineSchedule.shouldTick(expiresAt: expiresAt, now: .now)
    {
      TimelineView(AcpPermissionDeadlineTimelineSchedule(expiresAt: expiresAt)) { context in
        if let status = payload.deadlineStatus(
          now: context.date,
          lastMessageAt: lastMessageAt
        ) {
          identifiedStatusLabel(status)
        }
      }
    } else if let status = payload.deadlineStatus(now: .now, lastMessageAt: lastMessageAt) {
      identifiedStatusLabel(status)
    }
  }

  @ViewBuilder
  private func identifiedStatusLabel(
    _ status: AcpPermissionDeadlineStatus
  ) -> some View {
    let label = statusLabel(status)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(status.accessibilityValue)
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
        .accessibilityHidden(true)
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

struct AcpPermissionDeadlineTimelineSchedule: TimelineSchedule {
  let expiresAt: Date

  func entries(
    from startDate: Date,
    mode: TimelineScheduleMode
  ) -> AcpPermissionDeadlineTimelineEntries {
    AcpPermissionDeadlineTimelineEntries(startDate: startDate, expiresAt: expiresAt)
  }

  static func shouldTick(expiresAt: Date, now: Date) -> Bool {
    expiresAt > now
  }
}

struct AcpPermissionDeadlineTimelineEntries: Sequence, IteratorProtocol {
  private var nextDate: Date
  private let expiresAt: Date
  private var emittedExpiry = false

  init(startDate: Date, expiresAt: Date) {
    nextDate = startDate
    self.expiresAt = expiresAt
  }

  mutating func next() -> Date? {
    guard !emittedExpiry else {
      return nil
    }

    guard nextDate < expiresAt else {
      emittedExpiry = true
      return expiresAt
    }

    let current = nextDate
    nextDate = Swift.min(nextDate.addingTimeInterval(1), expiresAt)
    return current
  }
}

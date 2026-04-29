import Foundation
import HarnessMonitorKit
import SwiftUI

enum AcpRuntimePresentation: Equatable {
  case full
  case compact
}

struct AcpRuntimeView: View {
  let agentID: String
  let agentName: String
  let snapshot: AcpAgentSnapshot
  let inspect: AcpAgentInspectSnapshot?
  let observedAt: Date?
  let presentation: AcpRuntimePresentation

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      AcpRuntimeStatusStrip(
        agentID: agentID,
        agentName: agentName,
        snapshot: snapshot,
        inspect: inspect,
        observedAt: observedAt,
        presentation: presentation
      )
      if presentation == .full {
        AcpRuntimeDisclosure(agentID: agentID, inspect: inspect)
      }
    }
  }
}

struct AcpRuntimeStatusStrip: View {
  let agentID: String
  let agentName: String
  let snapshot: AcpAgentSnapshot
  let inspect: AcpAgentInspectSnapshot?
  let observedAt: Date?
  let presentation: AcpRuntimePresentation

  @State private var lastWatchdogAnnouncement: AcpRuntimeWatchdogAnnouncement?

  private var pendingPermissions: Int {
    inspect?.pendingPermissions ?? snapshot.pendingPermissions
  }

  private var promptDeadlineDate: Date? {
    guard let inspect, let observedAt, inspect.promptDeadlineRemainingMs > 0 else {
      return nil
    }
    return observedAt.addingTimeInterval(TimeInterval(inspect.promptDeadlineRemainingMs) / 1000)
  }

  private var watchdogState: String {
    inspect?.watchdogState ?? "unknown"
  }

  private var subtitle: String {
    switch presentation {
    case .full:
      snapshot.projectDir.isEmpty ? "ACP runtime active" : snapshot.projectDir
    case .compact:
      "Runtime telemetry"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("ACP runtime")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text(subtitle)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
      }
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
          statusChips
        }
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          statusChips
        }
      }
    }
    .padding(presentation == .full ? HarnessMonitorTheme.spacingMD : HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.accent.opacity(presentation == .full ? 0.12 : 0.08))
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .stroke(HarnessMonitorTheme.accent.opacity(0.25), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentRuntimeStrip(agentID))
    .onAppear {
      guard let inspect else {
        return
      }
      lastWatchdogAnnouncement = AcpRuntimeWatchdogAnnouncement(
        state: inspect.watchdogState,
        announcedAt: .now
      )
    }
    .onChange(of: inspect?.watchdogState) { oldValue, newValue in
      guard oldValue != newValue, let newValue else {
        return
      }
      announceWatchdogStateIfNeeded(newValue)
    }
  }

  @ViewBuilder
  private var statusChips: some View {
    AcpRuntimeChip(
      title: "Watchdog",
      value: AcpRuntimeWatchdogAnnouncementPolicy.label(for: watchdogState),
      systemImage: "shield.lefthalf.filled",
      tint: AcpRuntimeWatchdogAnnouncementPolicy.tint(for: watchdogState)
    )
    .accessibilityLiveRegion(AcpRuntimeWatchdogAnnouncementPolicy.liveRegion(for: watchdogState))
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentRuntimeWatchdog(agentID))

    AcpRuntimeChip(
      title: "Pending permissions",
      value: pendingPermissions.formatted(),
      systemImage: "person.badge.key",
      tint: pendingPermissions > 0 ? HarnessMonitorTheme.caution : HarnessMonitorTheme.secondaryInk
    )
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentRuntimePendingPermissions(agentID))

    if let promptDeadlineDate {
      AcpRuntimeDeadlineChip(deadline: promptDeadlineDate)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentRuntimeDeadline(agentID))
    }
  }

  private func announceWatchdogStateIfNeeded(_ state: String) {
    let now = Date()
    guard
      AcpRuntimeWatchdogAnnouncementPolicy.shouldAnnounce(
        state: state,
        lastAnnouncement: lastWatchdogAnnouncement,
        now: now
      )
    else {
      return
    }
    AccessibilityNotification.Announcement(
      AcpRuntimeWatchdogAnnouncementPolicy.message(agentName: agentName, state: state)
    ).post()
    lastWatchdogAnnouncement = AcpRuntimeWatchdogAnnouncement(state: state, announcedAt: now)
  }
}

struct AcpRuntimeWatchdogAnnouncement: Equatable {
  let state: String
  let announcedAt: Date
}

enum AcpRuntimeWatchdogAnnouncementPolicy {
  static func liveRegion(for state: String) -> HarnessMonitorAccessibilityLiveRegion {
    isAssertive(state) ? .assertive : .polite
  }

  static func label(for state: String) -> String {
    normalizedState(state)
      .split(separator: "_")
      .map(\.capitalized)
      .joined(separator: " ")
  }

  static func tint(for state: String) -> Color {
    switch normalizedState(state) {
    case "fired", "expired":
      HarnessMonitorTheme.danger
    case "warning", "stalling":
      HarnessMonitorTheme.caution
    case "active", "armed", "running":
      HarnessMonitorTheme.success
    default:
      HarnessMonitorTheme.secondaryInk
    }
  }

  static func message(agentName: String, state: String) -> String {
    "\(agentName) watchdog \(label(for: state).lowercased())"
  }

  static func shouldAnnounce(
    state: String,
    lastAnnouncement: AcpRuntimeWatchdogAnnouncement?,
    now: Date
  ) -> Bool {
    guard let lastAnnouncement else {
      return true
    }
    guard normalizedState(lastAnnouncement.state) == normalizedState(state) else {
      return true
    }
    let debounce = isAssertive(state) ? 60.0 : 30.0
    return now.timeIntervalSince(lastAnnouncement.announcedAt) >= debounce
  }

  private static func isAssertive(_ state: String) -> Bool {
    normalizedState(state) == "fired"
  }

  private static func normalizedState(_ state: String) -> String {
    state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

private struct AcpRuntimeChip: View {
  let title: String
  let value: String
  let systemImage: String
  let tint: Color

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: systemImage)
        .font(.caption)
      Text("\(title) \(value)")
        .scaledFont(.caption.weight(.semibold))
        .lineLimit(1)
    }
    .foregroundStyle(tint)
    .harnessPillPadding()
    .background(
      Capsule(style: .continuous)
        .fill(tint.opacity(0.12))
    )
    .overlay {
      Capsule(style: .continuous)
        .stroke(tint.opacity(0.25), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct AcpRuntimeDeadlineChip: View {
  let deadline: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      AcpRuntimeChip(
        title: "Prompt deadline",
        value: countdownLabel(now: context.date),
        systemImage: "timer",
        tint: remainingSeconds(now: context.date) <= 10
          ? HarnessMonitorTheme.caution : HarnessMonitorTheme.accent
      )
    }
  }

  private func countdownLabel(now: Date) -> String {
    let remaining = remainingSeconds(now: now)
    let minutes = remaining / 60
    let seconds = remaining % 60
    return "\(minutes):" + String(format: "%02d", seconds)
  }

  private func remainingSeconds(now: Date) -> Int {
    max(0, Int(deadline.timeIntervalSince(now).rounded(.down)))
  }
}

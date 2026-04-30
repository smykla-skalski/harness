import Foundation
import HarnessMonitorKit
import SwiftUI

enum AcpRuntimePresentation: Equatable {
  case full
  case compact
}

struct AcpRuntimeView: View {
  let runtimeState: AcpAgentRuntimeState
  let presentation: AcpRuntimePresentation

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      AcpRuntimeStatusStrip(
        runtimeState: runtimeState,
        presentation: presentation
      )
      if presentation == .full {
        AcpRuntimeDisclosure(runtimeState: runtimeState)
      }
    }
  }
}

struct AcpRuntimeStatusStrip: View {
  let runtimeState: AcpAgentRuntimeState
  let presentation: AcpRuntimePresentation

  @State private var lastWatchdogAnnouncement: AcpRuntimeWatchdogAnnouncement?

  private var promptDeadlineDate: Date? {
    guard
      let observedAt = runtimeState.promptDeadlineAnchorAt,
      let remaining = runtimeState.promptDeadlineRemainingMs
    else {
      return nil
    }
    return observedAt.addingTimeInterval(TimeInterval(remaining) / 1000)
  }

  private var subtitle: String {
    switch presentation {
    case .full:
      if let projectDir = runtimeState.projectDir, projectDir.isEmpty == false {
        projectDir
      } else {
        "ACP runtime active"
      }
    case .compact:
      "Runtime telemetry"
    }
  }

  private var watchdogSignal: AcpRuntimeWatchdogSignal? {
    guard let state = runtimeState.inspect?.watchdogState else {
      return nil
    }
    return AcpRuntimeWatchdogSignal(runtimeID: runtimeState.id, state: state)
  }

  private var watchdogAccessibilityMarkerText: String {
    [
      """
      live-region=\(AcpRuntimeWatchdogAnnouncementPolicy.liveRegion(
        for: runtimeState.watchdogDisplayState
      ))
      """,
      "state=\(runtimeState.watchdogDisplayState)",
    ].joined(separator: " ")
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
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.agentRuntimeStrip(runtimeState.agentId)
    )
    .accessibilityLabel("ACP runtime status")
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.agentRuntimeWatchdogAccessibilityState,
        text: watchdogAccessibilityMarkerText
      )
    }
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.toolCallTimelineAccessibilityState,
        text: ToolCallTimelineView.accessibilityStateMarkerText
      )
    }
    .onChange(of: watchdogSignal, initial: true) { oldValue, newValue in
      applyWatchdogAnnouncementEffect(
        AcpRuntimeWatchdogAnnouncementCoordinator.effect(
          from: oldValue,
          to: newValue,
          lastAnnouncement: lastWatchdogAnnouncement,
          agentName: runtimeState.agentName,
          now: .now
        )
      )
    }
  }

  @ViewBuilder private var statusChips: some View {
    AcpRuntimeChip(
      title: "Watchdog",
      value: AcpRuntimeWatchdogAnnouncementPolicy.label(for: runtimeState.watchdogDisplayState),
      systemImage: "shield.lefthalf.filled",
      tint: AcpRuntimeWatchdogAnnouncementPolicy.tint(for: runtimeState.watchdogDisplayState),
      accessibilityLabel: "Watchdog",
      accessibilityValue: AcpRuntimeWatchdogAnnouncementPolicy.label(
        for: runtimeState.watchdogDisplayState
      )
    )
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.agentRuntimeWatchdog(runtimeState.agentId)
    )

    AcpRuntimeChip(
      title: "Pending permissions",
      value: runtimeState.pendingPermissions.formatted(),
      systemImage: "person.badge.key",
      tint: runtimeState.pendingPermissions > 0
        ? HarnessMonitorTheme.caution : HarnessMonitorTheme.secondaryInk,
      accessibilityLabel: "Pending permissions",
      accessibilityValue: runtimeState.pendingPermissions.formatted()
    )
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.agentRuntimePendingPermissions(runtimeState.agentId)
    )

    if let promptDeadlineDate {
      AcpRuntimeDeadlineChip(deadline: promptDeadlineDate)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.agentRuntimeDeadline(runtimeState.agentId)
        )
    }
  }

  private func applyWatchdogAnnouncementEffect(
    _ effect: AcpRuntimeWatchdogAnnouncementEffect
  ) {
    switch effect {
    case .none:
      break
    case .clear:
      lastWatchdogAnnouncement = nil
    case .seed(let announcement):
      lastWatchdogAnnouncement = announcement
    case .announce(let message, let announcement):
      AccessibilityNotification.Announcement(message).post()
      lastWatchdogAnnouncement = announcement
    }
  }
}

struct AcpRuntimeWatchdogAnnouncement: Equatable {
  let state: String
  let announcedAt: Date
}

struct AcpRuntimeWatchdogSignal: Equatable {
  let runtimeID: String
  let state: String

  func announcement(at now: Date) -> AcpRuntimeWatchdogAnnouncement {
    AcpRuntimeWatchdogAnnouncement(state: state, announcedAt: now)
  }
}

enum AcpRuntimeWatchdogAnnouncementEffect: Equatable {
  case none
  case clear
  case seed(AcpRuntimeWatchdogAnnouncement)
  case announce(message: String, announcement: AcpRuntimeWatchdogAnnouncement)
}

enum AcpRuntimeWatchdogAnnouncementCoordinator {
  static func effect(
    from previousSignal: AcpRuntimeWatchdogSignal?,
    to newSignal: AcpRuntimeWatchdogSignal?,
    lastAnnouncement: AcpRuntimeWatchdogAnnouncement?,
    agentName: String,
    now: Date
  ) -> AcpRuntimeWatchdogAnnouncementEffect {
    guard let newSignal else {
      return .clear
    }

    let announcement = newSignal.announcement(at: now)
    guard let previousSignal else {
      return .seed(announcement)
    }
    guard previousSignal.runtimeID == newSignal.runtimeID else {
      return .seed(announcement)
    }
    guard previousSignal.state != newSignal.state else {
      return .none
    }
    guard
      AcpRuntimeWatchdogAnnouncementPolicy.shouldAnnounce(
        state: newSignal.state,
        lastAnnouncement: lastAnnouncement,
        now: now
      )
    else {
      return .none
    }
    return .announce(
      message: AcpRuntimeWatchdogAnnouncementPolicy.message(
        agentName: agentName,
        state: newSignal.state
      ),
      announcement: announcement
    )
  }
}

enum AcpRuntimeWatchdogAnnouncementPolicy {
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

  static func liveRegion(for state: String) -> String {
    isAssertive(state) ? "assertive" : "polite"
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
  let accessibilityLabel: String
  let accessibilityValue: String

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
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
  }
}

private struct AcpRuntimeDeadlineChip: View {
  let deadline: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      if remainingSeconds(now: context.date) > 0 {
        AcpRuntimeChip(
          title: "Prompt deadline",
          value: countdownLabel(now: context.date),
          systemImage: "timer",
          tint: remainingSeconds(now: context.date) <= 10
            ? HarnessMonitorTheme.caution : HarnessMonitorTheme.accent,
          accessibilityLabel: "Prompt deadline",
          accessibilityValue: accessibilityCountdownLabel(now: context.date)
        )
      }
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

  private func accessibilityCountdownLabel(now: Date) -> String {
    let remaining = remainingSeconds(now: now)
    if remaining == 1 {
      return "1 second remaining"
    }
    return "\(remaining) seconds remaining"
  }
}

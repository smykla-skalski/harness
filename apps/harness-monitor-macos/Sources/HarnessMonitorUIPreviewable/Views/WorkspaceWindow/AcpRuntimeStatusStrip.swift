import Foundation
import HarnessMonitorKit
import SwiftUI

enum AcpRuntimePresentation: Equatable {
  case full
  case compact
}

struct AcpRuntimeStatusStrip: View {
  /// Observe the clock tick here so the 1 Hz invalidation stays scoped to the strip instead of the
  /// wider agent detail hierarchy.
  let store: HarnessMonitorStore
  let runtimeState: AcpAgentRuntimeState
  let inspectStatus: AcpRuntimeInspectStatus
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
    if inspectStatus.phase != .ready {
      AcpRuntimeChip(
        title: "Inspect",
        value: inspectStatus.shortLabel,
        systemImage: AcpRuntimeInspectPresentation.systemImage(for: inspectStatus.phase),
        tint: AcpRuntimeInspectPresentation.tint(for: inspectStatus.phase),
        accessibilityLabel: "Runtime inspect",
        accessibilityValue: inspectStatus.accessibilityValue
      )
    }

    AcpRuntimeChip(
      title: "Watchdog",
      value:
        runtimeState.hasInspect
        ? AcpRuntimeWatchdogAnnouncementPolicy.label(for: runtimeState.watchdogDisplayState)
        : "Unknown",
      systemImage: "shield.lefthalf.filled",
      tint:
        runtimeState.hasInspect
        ? AcpRuntimeWatchdogAnnouncementPolicy.tint(for: runtimeState.watchdogDisplayState)
        : HarnessMonitorTheme.secondaryInk,
      accessibilityLabel: "Watchdog",
      accessibilityValue:
        runtimeState.hasInspect
        ? AcpRuntimeWatchdogAnnouncementPolicy.label(for: runtimeState.watchdogDisplayState)
        : "Unknown"
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
      AcpRuntimeDeadlineChip(deadline: promptDeadlineDate, now: store.acpRuntimeClockTick)
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

private enum AcpRuntimeInspectPresentation {
  static func tint(for phase: AcpRuntimeInspectPhase) -> Color {
    switch phase {
    case .ready:
      HarnessMonitorTheme.success
    case .waiting:
      HarnessMonitorTheme.secondaryInk
    case .retrying:
      HarnessMonitorTheme.accent
    case .stalled:
      HarnessMonitorTheme.caution
    case .unavailable:
      HarnessMonitorTheme.danger
    }
  }

  static func systemImage(for phase: AcpRuntimeInspectPhase) -> String {
    switch phase {
    case .ready:
      "checkmark.circle"
    case .waiting:
      "clock"
    case .retrying:
      "arrow.triangle.2.circlepath"
    case .stalled:
      "pause.circle"
    case .unavailable:
      "exclamationmark.triangle"
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

struct AcpRuntimeDeadlinePresentation: Equatable {
  let countdownLabel: String
  let accessibilityLabel: String
  let isUrgent: Bool

  static func presentation(deadline: Date, now: Date) -> Self? {
    let remaining = max(0, Int(deadline.timeIntervalSince(now).rounded(.down)))
    guard remaining > 0 else {
      return nil
    }
    let minutes = remaining / 60
    let seconds = remaining % 60
    let countdownLabel = "\(minutes):" + String(format: "%02d", seconds)
    let accessibilityLabel =
      if remaining == 1 {
        "1 second remaining"
      } else {
        "\(remaining) seconds remaining"
      }
    return Self(
      countdownLabel: countdownLabel,
      accessibilityLabel: accessibilityLabel,
      isUrgent: remaining <= 10
    )
  }
}

private struct AcpRuntimeDeadlineChip: View {
  let deadline: Date
  let now: Date

  var body: some View {
    if let presentation = AcpRuntimeDeadlinePresentation.presentation(
      deadline: deadline,
      now: now
    ) {
      AcpRuntimeChip(
        title: "Prompt deadline",
        value: presentation.countdownLabel,
        systemImage: "timer",
        tint: presentation.isUrgent ? HarnessMonitorTheme.caution : HarnessMonitorTheme.accent,
        accessibilityLabel: "Prompt deadline",
        accessibilityValue: presentation.accessibilityLabel
      )
    }
  }
}

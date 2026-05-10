import Foundation
import HarnessMonitorKit
import SwiftUI

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

struct AcpRuntimeChip: View {
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
        .fill(tint.opacity(0.08))
    )
    .overlay {
      Capsule(style: .continuous)
        .stroke(tint.opacity(0.18), lineWidth: 1)
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

enum AcpRuntimeDeadlineClock {
  @MainActor
  static func now(store: HarnessMonitorStore, localNow: Date) -> Date {
    store.currentAcpRuntimeClockNow(at: localNow) ?? localNow
  }

  static func shouldTick(deadline: Date?, now: Date) -> Bool {
    guard let deadline else {
      return false
    }
    return deadline.timeIntervalSince(now) > 0
  }

  static func sleepUntilNextTick() async -> Bool {
    do {
      try await Task.sleep(for: .seconds(1))
      return !Task.isCancelled
    } catch {
      return false
    }
  }
}

struct AcpRuntimeDeadlineChip: View {
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

public enum AcpRuntimeStatusEdgeAccent: Equatable {
  case fired
  case stalling
  case awaitingPermission
  case deadlineApproaching

  static let deadlineApproachWindowSeconds: TimeInterval = 30

  public static func classify(
    watchdogDisplayState: String,
    pendingPermissions: Int,
    promptDeadline: Date?,
    now: Date
  ) -> Self? {
    let normalized =
      watchdogDisplayState
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if normalized == "fired" || normalized == "expired" {
      return .fired
    }
    if normalized == "stalling" || normalized == "warning" {
      return .stalling
    }
    if pendingPermissions > 0 {
      return .awaitingPermission
    }
    if let promptDeadline {
      let remaining = promptDeadline.timeIntervalSince(now)
      if remaining > 0, remaining <= deadlineApproachWindowSeconds {
        return .deadlineApproaching
      }
    }
    return nil
  }

  public static func tint(for accent: Self?) -> Color? {
    switch accent {
    case .fired:
      HarnessMonitorTheme.danger
    case .stalling, .awaitingPermission, .deadlineApproaching:
      HarnessMonitorTheme.caution
    case .none:
      nil
    }
  }
}

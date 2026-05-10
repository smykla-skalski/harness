import Foundation
import HarnessMonitorKit
import SwiftUI

enum AcpRuntimePresentation: Equatable {
  case full
  case compact
}

struct AcpRuntimeStatusStrip: View {
  let store: HarnessMonitorStore
  let runtimeState: AcpAgentRuntimeState
  let inspectStatus: AcpRuntimeInspectStatus
  let presentation: AcpRuntimePresentation

  @State private var deadlineNow = Date.now
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

  private var detailLabel: String {
    switch presentation {
    case .full:
      if let projectDir = runtimeState.projectDir, projectDir.isEmpty == false {
        abbreviateHomePath(projectDir)
      } else {
        "Runtime telemetry available"
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

  private var edgeAccentTint: Color? {
    AcpRuntimeStatusEdgeAccent.tint(
      for: AcpRuntimeStatusEdgeAccent.classify(
        watchdogDisplayState: runtimeState.watchdogDisplayState,
        pendingPermissions: runtimeState.pendingPermissions,
        promptDeadline: promptDeadlineDate,
        now: deadlineNow
      )
    )
  }

  var body: some View {
    VStack(
      alignment: .leading,
      spacing: presentation == .full ? HarnessMonitorTheme.spacingSM : HarnessMonitorTheme.spacingXS
    ) {
      Text("ACP runtime")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(detailLabel)
        .scaledFont(presentation == .full ? .caption.monospaced() : .caption)
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
        .lineLimit(1)
        .truncationMode(.middle)
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
        .fill(HarnessMonitorTheme.ink.opacity(presentation == .full ? 0.05 : 0.04))
    )
    .overlay(alignment: .leading) {
      if let edgeAccentTint {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(edgeAccentTint)
          .frame(width: 3)
          .padding(.vertical, HarnessMonitorTheme.spacingXS)
          .padding(.leading, 1)
          .accessibilityHidden(true)
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.6), lineWidth: 1)
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
    .task(id: promptDeadlineDate) {
      await runDeadlineClockIfNeeded()
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

    if runtimeState.pendingPermissions > 0 {
      AcpRuntimeChip(
        title: "Pending permissions",
        value: runtimeState.pendingPermissions.formatted(),
        systemImage: "person.badge.key",
        tint: HarnessMonitorTheme.caution,
        accessibilityLabel: "Pending permissions",
        accessibilityValue: runtimeState.pendingPermissions.formatted()
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.agentRuntimePendingPermissions(runtimeState.agentId)
      )
    }

    if let promptDeadlineDate {
      AcpRuntimeDeadlineChip(deadline: promptDeadlineDate, now: deadlineNow)
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
    case .announce(_, let announcement):
      // Watchdog announcements flow through the timeline live-region so the
      // 10-second polite throttle applies. The strip seeds last-state for
      // its own debounce but does not post a second NSAccessibility event.
      lastWatchdogAnnouncement = announcement
    }
  }

  @MainActor
  private func runDeadlineClockIfNeeded() async {
    guard promptDeadlineDate != nil else {
      return
    }

    while !Task.isCancelled {
      let now = AcpRuntimeDeadlineClock.now(store: store, localNow: Date.now)
      deadlineNow = now
      guard AcpRuntimeDeadlineClock.shouldTick(deadline: promptDeadlineDate, now: now) else {
        return
      }
      guard await AcpRuntimeDeadlineClock.sleepUntilNextTick() else {
        return
      }
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

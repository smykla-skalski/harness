import HarnessMonitorKit
import Observation
import SwiftUI

extension AgentDetailSendUpdateSection {
  var isSessionReadOnly: Bool {
    store.isSessionReadOnly
  }

  var statusTint: Color {
    isSessionReadOnly ? HarnessMonitorTheme.secondaryInk : HarnessMonitorTheme.caution
  }

  var statusSymbolName: String {
    isSessionReadOnly ? "lock.fill" : "exclamationmark.circle"
  }
}

@MainActor
@Observable
final class AgentDetailDeadlineClockState {
  private var now = Date.now

  func presentation(for deadline: Date?) -> AcpRuntimeDeadlinePresentation? {
    guard let deadline else { return nil }
    return AcpRuntimeDeadlinePresentation.presentation(deadline: deadline, now: now)
  }

  func run(store: HarnessMonitorStore, deadline: Date?) async {
    guard deadline != nil else {
      return
    }

    while !Task.isCancelled {
      now = AcpRuntimeDeadlineClock.now(store: store, localNow: Date.now)
      guard AcpRuntimeDeadlineClock.shouldTick(deadline: deadline, now: now) else {
        return
      }
      guard await AcpRuntimeDeadlineClock.sleepUntilNextTick() else {
        return
      }
    }
  }
}

struct AgentDetailDeadlineSendButton: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agentID: String
  let statusMessage: String?
  let promptDeadlineDate: Date?
  let deadlineClock: AgentDetailDeadlineClockState
  let action: HarnessInlineActionButton.Action

  private var deadlinePresentation: AcpRuntimeDeadlinePresentation? {
    deadlineClock.presentation(for: promptDeadlineDate)
  }

  private var title: String {
    if let deadlinePresentation, deadlinePresentation.isUrgent {
      return "Send · \(deadlinePresentation.countdownLabel)"
    }
    return "Send"
  }

  var body: some View {
    HarnessInlineActionButton(
      title: title,
      actionID: .sendSignal(sessionID: sessionID, agentID: agentID),
      store: store,
      variant: .prominent,
      tint: nil,
      isExternallyDisabled: statusMessage != nil,
      accessibilityIdentifier: HarnessMonitorAccessibility.agentDetailSignalSend,
      action: action
    )
    .accessibilityLabel("Send Update")
    .accessibilityValue(statusMessage ?? "")
  }
}

struct AgentDetailComposerStatusRow: View {
  private static let horizontalMinWidth: CGFloat = 360

  let store: HarnessMonitorStore
  let statusMessage: String?
  let statusTint: Color
  let statusSymbolName: String
  let promptDeadlineDate: Date?
  let deadlineClock: AgentDetailDeadlineClockState

  @State private var fitsHorizontally = true

  private var deadlinePresentation: AcpRuntimeDeadlinePresentation? {
    deadlineClock.presentation(for: promptDeadlineDate)
  }

  private var deadlineStatusLabel: String? {
    guard let deadlinePresentation, !deadlinePresentation.isUrgent else {
      return nil
    }
    return "Deadline \(deadlinePresentation.countdownLabel)"
  }

  var body: some View {
    if statusMessage != nil || deadlineStatusLabel != nil {
      content
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.width
        } action: { width in
          let next = width >= Self.horizontalMinWidth
          if fitsHorizontally != next {
            fitsHorizontally = next
          }
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentDetailSignalStatus)
    }
  }

  @ViewBuilder private var content: some View {
    if fitsHorizontally {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        statusLabel
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        deadlineLabel
      }
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        statusLabel
        deadlineLabel
      }
    }
  }

  @ViewBuilder private var statusLabel: some View {
    if let statusMessage {
      Label {
        Text(statusMessage)
          .scaledFont(.caption)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: statusSymbolName)
          .scaledFont(.caption.weight(.semibold))
          .accessibilityHidden(true)
      }
      .foregroundStyle(statusTint)
      .accessibilityElement(children: .combine)
    }
  }

  @ViewBuilder private var deadlineLabel: some View {
    if let deadlineStatusLabel {
      Label {
        Text(deadlineStatusLabel)
          .scaledFont(.caption)
          .lineLimit(1)
      } icon: {
        Image(systemName: "clock")
          .scaledFont(.caption.weight(.semibold))
          .accessibilityHidden(true)
      }
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Prompt deadline")
      .accessibilityValue(deadlinePresentation?.accessibilityLabel ?? deadlineStatusLabel)
    }
  }
}

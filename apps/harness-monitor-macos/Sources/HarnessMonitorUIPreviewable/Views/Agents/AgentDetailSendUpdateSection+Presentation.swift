import HarnessMonitorKit
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

  var composerStatusRow: some View {
    AgentDetailComposerStatusRow(
      store: store,
      statusMessage: statusMessage,
      statusTint: statusTint,
      statusSymbolName: statusSymbolName,
      promptDeadlineDate: promptDeadlineDate
    )
  }
}

struct AgentDetailDeadlineSendButton: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agentID: String
  let statusMessage: String?
  let promptDeadlineDate: Date?
  let action: HarnessInlineActionButton.Action

  @State private var deadlineNow = Date.now

  private var deadlinePresentation: AcpRuntimeDeadlinePresentation? {
    guard let promptDeadlineDate else { return nil }
    return AcpRuntimeDeadlinePresentation.presentation(
      deadline: promptDeadlineDate,
      now: deadlineNow
    )
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
    .task(id: promptDeadlineDate) {
      await runDeadlineClockIfNeeded()
    }
  }

  @MainActor
  private func runDeadlineClockIfNeeded() async {
    await AgentDetailDeadlineClock.run(
      store: store,
      deadline: promptDeadlineDate,
      assignNow: { deadlineNow = $0 }
    )
  }
}

private struct AgentDetailComposerStatusRow: View {
  private static let horizontalMinWidth: CGFloat = 360

  let store: HarnessMonitorStore
  let statusMessage: String?
  let statusTint: Color
  let statusSymbolName: String
  let promptDeadlineDate: Date?

  @State private var deadlineNow = Date.now
  @State private var fitsHorizontally = true

  private var deadlinePresentation: AcpRuntimeDeadlinePresentation? {
    guard let promptDeadlineDate else { return nil }
    return AcpRuntimeDeadlinePresentation.presentation(
      deadline: promptDeadlineDate,
      now: deadlineNow
    )
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
        .task(id: promptDeadlineDate) {
          await runDeadlineClockIfNeeded()
        }
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

  @MainActor
  private func runDeadlineClockIfNeeded() async {
    await AgentDetailDeadlineClock.run(
      store: store,
      deadline: promptDeadlineDate,
      assignNow: { deadlineNow = $0 }
    )
  }
}

private enum AgentDetailDeadlineClock {
  @MainActor
  static func run(
    store: HarnessMonitorStore,
    deadline: Date?,
    assignNow: @escaping (Date) -> Void
  ) async {
    guard deadline != nil else {
      return
    }

    while !Task.isCancelled {
      let now = AcpRuntimeDeadlineClock.now(store: store, localNow: Date.now)
      assignNow(now)
      guard AcpRuntimeDeadlineClock.shouldTick(deadline: deadline, now: now) else {
        return
      }
      guard await AcpRuntimeDeadlineClock.sleepUntilNextTick() else {
        return
      }
    }
  }
}

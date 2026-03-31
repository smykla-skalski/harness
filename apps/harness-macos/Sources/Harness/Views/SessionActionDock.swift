import HarnessKit
import Observation
import SwiftUI

struct SessionActionDock: View {
  let store: HarnessStore
  let detail: SessionDetail

  private var firstTaskID: String? {
    detail.tasks.first?.taskId
  }

  private var firstAgentID: String? {
    detail.agents.first?.agentId
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Action Flow")
            .font(.system(.headline, design: .rounded, weight: .semibold))
          Text("Pick a lane, then use the inspector to submit the change.")
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          if store.isSessionActionInFlight {
            HarnessSpinner()
              .transition(.opacity)
          } else if !store.lastAction.isEmpty {
            Text(store.lastAction)
              .font(.caption.bold())
              .foregroundStyle(HarnessTheme.success)
              .transition(.opacity)
          }
          Text("\(detail.tasks.count) tasks · \(detail.agents.count) agents")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .animation(.spring(duration: 0.2), value: store.isSessionActionInFlight)
      }

      HStack(spacing: 12) {
        flowButton(
          title: "Task Flow",
          subtitle: "Create, reassign, checkpoint",
          symbol: "checklist",
          action: focusFirstTask
        )
        flowButton(
          title: "People Flow",
          subtitle: "Change roles and leadership",
          symbol: "person.2",
          action: focusFirstAgent
        )
        flowButton(
          title: "Observe Flow",
          subtitle: "Surface and triage issues",
          symbol: "eye",
          action: focusObserver
        )
      }
    }
  }

  private func flowButton(
    title: String,
    subtitle: String,
    symbol: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        Label(title, systemImage: symbol)
          .font(.system(.headline, design: .rounded, weight: .semibold))
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
    }
    .harnessInteractiveCardButtonStyle()
  }

  private func focusFirstTask() {
    guard let taskID = firstTaskID else {
      return
    }
    store.inspect(taskID: taskID)
  }

  private func focusFirstAgent() {
    guard let agentID = firstAgentID else {
      return
    }
    store.inspect(agentID: agentID)
  }

  private func focusObserver() {
    store.inspectObserver()
  }
}

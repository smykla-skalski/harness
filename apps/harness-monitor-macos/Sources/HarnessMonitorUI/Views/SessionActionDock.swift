import HarnessMonitorKit
import SwiftUI

struct SessionActionDock: View {
  let detail: SessionDetail
  let isSessionActionInFlight: Bool
  let lastAction: String
  let inspectTask: (String) -> Void
  let inspectAgent: (String) -> Void
  let inspectObserver: () -> Void

  private var firstTaskID: String? {
    detail.tasks.first?.taskId
  }

  private var firstAgentID: String? {
    detail.agents.first?.agentId
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Action Flow")
            .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
          Text("Pick a lane, then use the inspector to submit the change.")
            .scaledFont(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          if isSessionActionInFlight {
            HarnessMonitorSpinner()
              .transition(.opacity)
          } else if !lastAction.isEmpty {
            Text(lastAction)
              .scaledFont(.caption.bold())
              .foregroundStyle(HarnessMonitorTheme.success)
              .accessibilityIdentifier(HarnessMonitorAccessibility.actionToast)
              .transition(.opacity)
          }
          Text("\(detail.tasks.count) \(detail.tasks.count == 1 ? "task" : "tasks") · \(detail.agents.count) \(detail.agents.count == 1 ? "agent" : "agents")")
            .scaledFont(.caption.monospacedDigit())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        .animation(.spring(duration: 0.2), value: isSessionActionInFlight)
        .animation(.spring(duration: 0.2), value: lastAction.isEmpty)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: HarnessMonitorTheme.sectionSpacing) {
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
        VStack(spacing: HarnessMonitorTheme.itemSpacing) {
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
  }

  private func flowButton(
    title: String,
    subtitle: String,
    symbol: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        Label(title, systemImage: symbol)
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        Text(subtitle)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(HarnessMonitorTheme.cardPadding)
    }
    .harnessInteractiveCardButtonStyle()
  }

  private func focusFirstTask() {
    guard let taskID = firstTaskID else {
      return
    }
    inspectTask(taskID)
  }

  private func focusFirstAgent() {
    guard let agentID = firstAgentID else {
      return
    }
    inspectAgent(agentID)
  }

  private func focusObserver() {
    inspectObserver()
  }
}

#Preview("Action flow") {
  SessionActionDock(
    detail: PreviewFixtures.detail,
    isSessionActionInFlight: false,
    lastAction: "Observe action queued",
    inspectTask: { _ in },
    inspectAgent: { _ in },
    inspectObserver: {}
  )
  .padding()
  .frame(width: 960)
}

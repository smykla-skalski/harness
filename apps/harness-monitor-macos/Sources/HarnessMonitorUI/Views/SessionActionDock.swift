import HarnessMonitorKit
import SwiftUI

struct SessionActionDock: View {
  let detail: SessionDetail
  let inspectTask: (String) -> Void
  let inspectAgent: (String) -> Void
  let inspectObserver: () -> Void
  let openAgentTui: () -> Void
  let openCodexFlow: () -> Void

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
        let taskWord = detail.tasks.count == 1 ? "task" : "tasks"
        let agentWord = detail.agents.count == 1 ? "agent" : "agents"
        Text("\(detail.tasks.count) \(taskWord) · \(detail.agents.count) \(agentWord)")
          .scaledFont(.caption.monospacedDigit())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: HarnessMonitorTheme.sectionSpacing) {
          flowButton(
            title: "Task Flow",
            subtitle: "Create, reassign, checkpoint",
            symbol: "checklist",
            action: focusFirstTask,
            accessibilityID: nil
          )
          flowButton(
            title: "People Flow",
            subtitle: "Change roles and leadership",
            symbol: "person.2",
            action: focusFirstAgent,
            accessibilityID: nil
          )
          flowButton(
            title: "Observe Flow",
            subtitle: "Surface and triage issues",
            symbol: "eye",
            action: focusObserver,
            accessibilityID: nil
          )
          flowButton(
            title: "Agent TUI",
            subtitle: "Drive Copilot or Codex",
            symbol: "terminal",
            action: openAgentTui,
            accessibilityID: HarnessMonitorAccessibility.agentTuiButton
          )
          flowButton(
            title: "Codex Flow",
            subtitle: "Ask for a report or patch",
            symbol: "sparkles",
            action: openCodexFlow,
            accessibilityID: HarnessMonitorAccessibility.codexFlowButton
          )
        }
        VStack(spacing: HarnessMonitorTheme.itemSpacing) {
          flowButton(
            title: "Task Flow",
            subtitle: "Create, reassign, checkpoint",
            symbol: "checklist",
            action: focusFirstTask,
            accessibilityID: nil
          )
          flowButton(
            title: "People Flow",
            subtitle: "Change roles and leadership",
            symbol: "person.2",
            action: focusFirstAgent,
            accessibilityID: nil
          )
          flowButton(
            title: "Observe Flow",
            subtitle: "Surface and triage issues",
            symbol: "eye",
            action: focusObserver,
            accessibilityID: nil
          )
          flowButton(
            title: "Agent TUI",
            subtitle: "Drive Copilot or Codex",
            symbol: "terminal",
            action: openAgentTui,
            accessibilityID: HarnessMonitorAccessibility.agentTuiButton
          )
          flowButton(
            title: "Codex Flow",
            subtitle: "Ask for a report or patch",
            symbol: "sparkles",
            action: openCodexFlow,
            accessibilityID: HarnessMonitorAccessibility.codexFlowButton
          )
        }
      }
    }
  }

  private func flowButton(
    title: String,
    subtitle: String,
    symbol: String,
    action: @escaping () -> Void,
    accessibilityID: String?
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
    .optionalAccessibilityIdentifier(accessibilityID)
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

extension View {
  @ViewBuilder
  fileprivate func optionalAccessibilityIdentifier(_ value: String?) -> some View {
    if let value {
      accessibilityIdentifier(value)
    } else {
      self
    }
  }
}

#Preview("Action flow") {
  SessionActionDock(
    detail: PreviewFixtures.detail,
    inspectTask: { _ in },
    inspectAgent: { _ in },
    inspectObserver: {},
    openAgentTui: {},
    openCodexFlow: {}
  )
  .padding()
  .frame(width: 960)
}

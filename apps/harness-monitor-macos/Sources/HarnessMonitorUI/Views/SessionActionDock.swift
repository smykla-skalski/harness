import HarnessMonitorKit
import SwiftUI

struct SessionActionDock: View {
  let detail: SessionDetail
  let inspectTask: (String) -> Void
  let inspectAgent: (String) -> Void
  let inspectObserver: () -> Void
  let openAgentTui: () -> Void
  let isCodexFlowAvailable: Bool
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
          codexFlowButton
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
          codexFlowButton
        }
      }
    }
  }

  private var codexFlowButton: some View {
    flowButton(
      title: "Codex Flow",
      subtitle: "Ask for a report or patch",
      symbol: "sparkles",
      action: openCodexFlow,
      accessibilityID: HarnessMonitorAccessibility.codexFlowButton
    )
    .disabled(!isCodexFlowAvailable)
    .overlay {
      if !isCodexFlowAvailable {
        CodexFlowWIPOverlay()
          .accessibilityIdentifier(HarnessMonitorAccessibility.codexFlowWIPBadge)
          .allowsHitTesting(false)
      }
    }
    .help(
      isCodexFlowAvailable
        ? "Ask Codex for a report or patch."
        : "Codex Flow is a work in progress and currently unavailable."
    )
    .accessibilityValue(isCodexFlowAvailable ? "" : "Work in progress")
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
    isCodexFlowAvailable: false,
    openCodexFlow: {}
  )
  .padding()
  .frame(width: 960)
}

private struct CodexFlowWIPOverlay: View {
  var body: some View {
    GeometryReader { proxy in
      let chromeShape = RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
        style: .continuous
      )

      ZStack {
        Circle()
          .fill(HarnessMonitorTheme.ink.opacity(0.16))
          .frame(width: 152, height: 152)
          .blur(radius: 28)

        HStack(spacing: HarnessMonitorTheme.spacingMD) {
          Spacer(minLength: 0)
          Image(systemName: "hammer.circle.fill")
            .font(.system(size: 34, weight: .semibold, design: .rounded))
          Text("WIP")
            .scaledFont(.system(.title2, design: .rounded, weight: .black))
            .textCase(.uppercase)
            .tracking(HarnessMonitorTheme.uppercaseTracking * 1.5)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, HarnessMonitorTheme.spacingLG)
        .foregroundStyle(HarnessMonitorTheme.ink.opacity(0.5))
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .compositingGroup()
      .clipShape(chromeShape)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityLabel("Work in progress")
  }
}

import HarnessMonitorKit
import SwiftUI

struct SessionActionDock: View {
  private struct FlowButtonDetails {
    let title: String
    let subtitle: String
    let symbol: String
    let helpText: String
    let accessibilityID: String?
  }

  let detail: SessionDetail
  let createTask: () -> Void
  let inspectObserver: () -> Void
  let openAgents: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Action Flow")
            .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
          Text("Pick a lane to drive the session forward.")
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

      HarnessMonitorAdaptiveGridLayout(
        minimumColumnWidth: 180,
        maximumColumns: 5,
        spacing: HarnessMonitorTheme.sectionSpacing
      ) {
        flowButton(
          FlowButtonDetails(
            title: "Task Flow",
            subtitle: "Create new task in this session",
            symbol: "checklist",
            helpText: "Open the create-task sheet for this session.",
            accessibilityID: nil
          ),
          action: createTask,
        )
        flowButton(
          FlowButtonDetails(
            title: "Observe Flow",
            subtitle: "Surface and triage issues",
            symbol: "eye",
            helpText: "Open the session observer.",
            accessibilityID: nil
          ),
          action: focusObserver,
        )
        flowButton(
          FlowButtonDetails(
            title: "Agents",
            subtitle: "Drive unified agent workflows",
            symbol: "terminal",
            helpText: "Open the unified Agents workspace to launch and manage sessions.",
            accessibilityID: HarnessMonitorAccessibility.agentsActionButton
          ),
          action: openAgents,
        )
      }
    }
  }

  private func flowButton(
    _ details: FlowButtonDetails,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        Label(details.title, systemImage: details.symbol)
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        Text(details.subtitle)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(HarnessMonitorTheme.cardPadding)
    }
    .harnessInteractiveCardButtonStyle()
    .help(details.helpText)
    .optionalAccessibilityIdentifier(details.accessibilityID)
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
    createTask: {},
    inspectObserver: {},
    openAgents: {}
  )
  .padding()
  .frame(width: 960)
}

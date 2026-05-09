import SwiftUI

#Preview("Session sidebar row") {
  @Previewable @State var selection: SessionSelection? = nil

  SessionSidebarRowSelectionPreview(selection: $selection)
    .frame(width: 260, height: 220)
    .environment(\.controlActiveState, .key)
}

#Preview("Session sidebar row - Largest text") {
  @Previewable @State var selection: SessionSelection? = .agent(
    sessionID: SessionSidebarRowPreviewFixtures.sessionID,
    agentID: SessionSidebarRowPreviewFixtures.workersAgentID
  )

  SessionSidebarRowSelectionPreview(selection: $selection)
    .environment(
      \.fontScale,
      HarnessMonitorTextSize.scale(at: HarnessMonitorTextSize.scales.count - 1)
    )
    .frame(width: 260, height: 220)
    .environment(\.controlActiveState, .key)
}

struct SessionSidebarRowPreviewContent: View {
  var body: some View {
    SessionSidebarRow(
      title: "Workers",
      systemImage: "person.crop.circle",
      severityShape: .dot,
      severityTint: .orange
    ) { metrics in
      SessionSidebarDragHandle(metrics: metrics)
    }
  }
}

private struct SessionSidebarRowSelectionPreview: View {
  @Binding var selection: SessionSelection?

  var body: some View {
    List(selection: $selection) {
      Section {
        SessionSidebarRow(
          title: "Overview",
          systemImage: "square.grid.2x2"
        )
        .tag(SessionSelection.route(.overview))

        SessionSidebarRow(
          title: "Workers",
          systemImage: "person.crop.circle",
          severityShape: .dot,
          severityTint: .orange
        ) { metrics in
          SessionSidebarDragHandle(metrics: metrics)
        }
        .tag(
          SessionSelection.agent(
            sessionID: SessionSidebarRowPreviewFixtures.sessionID,
            agentID: SessionSidebarRowPreviewFixtures.workersAgentID
          )
        )

        SessionSidebarRow(
          title: "Needs follow-up",
          systemImage: "checklist.checked",
          severityShape: .alert,
          severityTint: .red
        )
        .tag(
          SessionSelection.task(
            sessionID: SessionSidebarRowPreviewFixtures.sessionID,
            taskID: SessionSidebarRowPreviewFixtures.followUpTaskID
          )
        )
      } header: {
        Text("Sidebar")
          .padding(.top, HarnessMonitorTheme.spacingLG)
      }
    }
    .listStyle(.sidebar)
  }
}

private enum SessionSidebarRowPreviewFixtures {
  static let sessionID = "preview-session"
  static let workersAgentID = "agent-workers"
  static let followUpTaskID = "task-follow-up"
}

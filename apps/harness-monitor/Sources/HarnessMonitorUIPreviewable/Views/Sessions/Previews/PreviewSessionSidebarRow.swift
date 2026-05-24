import SwiftUI

#Preview("Session sidebar row") {
  @Previewable @State var selection: SessionSelection?

  SessionSidebarRowSelectionPreviewContent(selection: $selection)
    .frame(width: 260, height: 220)
    .harnessPreviewSceneAppearance()
    .environment(\.controlActiveState, .key)
}

#Preview("Session sidebar row - Smallest text") {
  @Previewable @State var selection: SessionSelection? = .route(.overview)

  SessionSidebarRowSelectionPreviewContent(selection: $selection)
    .frame(width: 260, height: 220)
    .harnessPreviewSceneAppearance(textSizeIndex: 0)
    .environment(\.controlActiveState, .key)
}

#Preview("Session sidebar row - Largest text") {
  @Previewable @State var selection: SessionSelection? = .agent(
    sessionID: SessionSidebarRowPreviewFixtures.sessionID,
    agentID: SessionSidebarRowPreviewFixtures.workersAgentID
  )

  SessionSidebarRowSelectionPreviewContent(selection: $selection)
    .frame(width: 260, height: 220)
    .harnessPreviewSceneAppearance(textSizeIndex: HarnessMonitorTextSize.scales.count - 1)
    .environment(\.controlActiveState, .key)
}

struct SessionSidebarRowPreviewContent: View {
  var body: some View {
    SessionSidebarRow(
      title: "Workers",
      systemImage: "person.crop.circle",
      severityShape: .dot,
      severityTint: .orange
    )
  }
}

struct SessionSidebarRowSelectionPreviewContent: View {
  @Binding var selection: SessionSelection?
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex

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
        )
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
    .environment(\.sidebarRowSize, sidebarRowSize)
  }

  private var sidebarRowSize: SidebarRowSize {
    switch HarnessMonitorTextSize.normalizedIndex(textSizeIndex) {
    case ..<HarnessMonitorTextSize.defaultIndex:
      .small
    case HarnessMonitorTextSize.defaultIndex..<HarnessMonitorTextSize.scales.count - 1:
      .medium
    default:
      .large
    }
  }
}

private enum SessionSidebarRowPreviewFixtures {
  static let sessionID = "preview-session"
  static let workersAgentID = "agent-workers"
  static let followUpTaskID = "task-follow-up"
}

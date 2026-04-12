import HarnessMonitorKit
import SwiftUI

struct AgentTuiSidebar: View {
  @Binding var selection: AgentTuiSheetSelection
  let agentTuis: [AgentTuiSnapshot]
  let sessionTitlesByID: [String: String]
  let refresh: () -> Void
  @Environment(\.fontScale) private var fontScale

  private var rowPadding: CGFloat {
    HarnessMonitorTheme.spacingXS * fontScale
  }

  private var selectionBinding: Binding<AgentTuiSheetSelection?> {
    Binding(
      get: { selection },
      set: { selection = $0 ?? .create }
    )
  }

  private var activeTuis: [AgentTuiSnapshot] {
    agentTuis.filter { $0.status.isActive }
  }

  private var inactiveTuis: [AgentTuiSnapshot] {
    agentTuis.filter { !$0.status.isActive }
  }

  var body: some View {
    List(selection: selectionBinding) {
      Label("Create", systemImage: "plus.rectangle")
        .scaledFont(.body)
        .padding(.vertical, rowPadding)
        .tag(AgentTuiSheetSelection.create)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiCreateTab)

      if !activeTuis.isEmpty {
        Section("Active") {
          ForEach(activeTuis) { tui in
            AgentTuiSidebarRow(
              snapshot: tui,
              title: sessionTitlesByID[tui.tuiId] ?? "Agent session"
            )
            .padding(.vertical, rowPadding)
            .tag(AgentTuiSheetSelection.session(tui.tuiId))
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiTab(tui.tuiId))
          }
        }
      }

      if !inactiveTuis.isEmpty {
        Section("Inactive") {
          ForEach(inactiveTuis) { tui in
            AgentTuiSidebarRow(
              snapshot: tui,
              title: sessionTitlesByID[tui.tuiId] ?? "Agent session"
            )
            .padding(.vertical, rowPadding)
            .tag(AgentTuiSheetSelection.session(tui.tuiId))
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiTab(tui.tuiId))
          }
        }
      }
    }
    .listStyle(.sidebar)
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button(action: refresh) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRefreshButton)
      }
    }
  }
}

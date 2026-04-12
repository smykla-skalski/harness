import SwiftUI

struct AgentTuiSidebar: View {
  @Binding var selection: AgentTuiSheetSelection
  let orderedSessionIDs: [String]
  let titleForSessionID: (String) -> String
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

  var body: some View {
    List(selection: selectionBinding) {
      Label("Create", systemImage: "plus.rectangle")
        .scaledFont(.body)
        .padding(.vertical, rowPadding)
        .tag(AgentTuiSheetSelection.create)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiCreateTab)

      if !orderedSessionIDs.isEmpty {
        Section("Sessions") {
          ForEach(orderedSessionIDs, id: \.self) { sessionID in
            Label(titleForSessionID(sessionID), systemImage: "terminal")
              .scaledFont(.body)
              .padding(.vertical, rowPadding)
              .tag(AgentTuiSheetSelection.session(sessionID))
              .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiTab(sessionID))
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

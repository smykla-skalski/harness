import HarnessMonitorKit
import SwiftUI

struct SidebarToolbarCreateMenuToolbarItem: ToolbarContent {
  let store: HarnessMonitorStore
  let canCreateTask: Bool

  private var createMenuAccessibilityValue: String {
    canCreateTask
      ? "New Agent and New Task available"
      : "New Agent available. New Task unavailable until a writable session is selected"
  }

  var body: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      SidebarCreateMenu(
        store: store,
        canCreateTask: canCreateTask,
        menuStateValue: createMenuAccessibilityValue
      )
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)
  }
}

private struct SidebarCreateMenu: View {
  let store: HarnessMonitorStore
  let canCreateTask: Bool
  let menuStateValue: String
  @Environment(\.openWindow)
  private var openWindow

  var body: some View {
    Menu {
      Button("New Agent", action: openNewAgent)
        .harnessMCPMenuItem(
          HarnessMonitorAccessibility.sidebarCreateMenuNewAgentItem,
          label: "New Agent"
        )

      Button("New Task", action: openNewTask)
        .disabled(!canCreateTask)
        .harnessMCPMenuItem(
          HarnessMonitorAccessibility.sidebarCreateMenuNewTaskItem,
          label: "New Task",
          enabled: canCreateTask
        )
    } label: {
      Label("Create", systemImage: "plus")
    }
    .help("Create agent or task")
    .menuIndicator(.hidden)
    .accessibilityLabel("Create")
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarCreateMenuButton)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarCreateMenuButtonFrame)
    .harnessMCPButton(
      HarnessMonitorAccessibility.sidebarCreateMenuButton,
      label: "Create",
      value: menuStateValue
    )
  }

  private func openNewAgent() {
    store.requestWorkspaceCreateEntryPoint(
      .agent,
      sessionID: store.selectedSession?.session.sessionId
    )
    openWindow.openHarnessSessionWindow(sessionID: store.selectedSession?.session.sessionId)
  }

  private func openNewTask() {
    store.requestCreateTaskSheet()
  }
}

struct SidebarToolbarFilterToolbarItem: ToolbarContent {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      SidebarFilterMenu(store: store, controls: controls)
    }

    ToolbarSpacer(.fixed, placement: .automatic)
  }
}

struct SidebarFilterStateMarker: View {
  let controls: HarnessMonitorStore.SessionControlsSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice
  let isSidebarSearchPresented: Bool

  private var sidebarFilterStateValue: String {
    [
      "status=\(controls.sessionFilter.rawValue)",
      "focus=\(controls.sessionFocusFilter.rawValue)",
      "sort=\(controls.sessionSortOrder.rawValue)",
      "visible=\(searchResults.filteredSessionCount)",
      "total=\(searchResults.totalSessionCount)",
      "search=\(controls.searchText)",
    ].joined(separator: ", ")
  }

  private var sidebarSearchStateValue: String {
    [
      "presented=\(isSidebarSearchPresented)",
      "active=\(isSidebarSearchPresented)",
      "visible=true",
    ].joined(separator: ", ")
  }

  var body: some View {
    if HarnessMonitorUITestEnvironment.searchMarkersEnabled {
      Group {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.sidebarFilterState,
          text: sidebarFilterStateValue
        )
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.sidebarSearchState,
          text: sidebarSearchStateValue
        )
      }
    }
  }
}

@MainActor
enum SidebarFilterVisibilityPolicy {
  static func hasActiveFilters(
    in controls: HarnessMonitorStore.SessionControlsSlice
  ) -> Bool {
    !controls.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || controls.sessionFilter != .all
      || controls.sessionFocusFilter != .all
      || controls.sessionSortOrder != .recentActivity
  }
}

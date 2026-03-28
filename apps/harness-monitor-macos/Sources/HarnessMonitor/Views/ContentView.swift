import HarnessMonitorKit
import Observation
import SwiftUI

struct ContentView: View {
  @Bindable var store: MonitorStore
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var showsPreferences = false

  private var selectedDetail: SessionDetail? {
    guard let sessionID = store.selectedSessionID,
      let detail = store.selectedSession,
      detail.session.sessionId == sessionID
    else {
      return nil
    }
    return detail
  }

  var body: some View {
    ZStack {
      MonitorTheme.canvas

      NavigationSplitView(columnVisibility: $columnVisibility) {
        SidebarView(store: store)
          .navigationSplitViewColumnWidth(min: 300, ideal: 350)
      } content: {
        NavigationStack {
          Group {
            if let detail = selectedDetail {
              SessionCockpitView(
                store: store,
                detail: detail,
                timeline: store.timeline
              )
            } else {
              SessionsBoardView(store: store)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityFrameMarker(MonitorAccessibility.contentRoot)
        }
        .searchable(text: $store.searchText, prompt: "Search sessions, projects, leaders")
        .navigationTitle("Harness Monitor")
        .toolbar {
          ToolbarItem(placement: .navigation) {
            Button(action: toggleSidebar) {
              Label("Toggle Sidebar", systemImage: "sidebar.leading")
            }
            .help(columnVisibility == .all ? "Hide Sidebar" : "Show Sidebar")
            .accessibilityIdentifier(MonitorAccessibility.sidebarToggleButton)
          }

          ToolbarItemGroup {
            Button {
              Task {
                await store.refresh()
              }
            } label: {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityIdentifier(MonitorAccessibility.refreshButton)

            Button {
              showsPreferences.toggle()
            } label: {
              Label("Daemon", systemImage: "gearshape.2")
            }
            .accessibilityIdentifier(MonitorAccessibility.daemonPreferencesButton)
          }
        }
        .navigationSplitViewColumnWidth(min: 600, ideal: 840)
      } detail: {
        InspectorColumnView(store: store)
          .navigationSplitViewColumnWidth(min: 320, ideal: 380)
      }
      .navigationSplitViewStyle(.balanced)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(isPresented: $showsPreferences) {
      PreferencesView(store: store)
        .frame(minWidth: 620, minHeight: 420)
    }
  }

  private func toggleSidebar() {
    withAnimation(.easeInOut(duration: 0.2)) {
      if columnVisibility == .all {
        columnVisibility = .doubleColumn
      } else {
        columnVisibility = .all
      }
    }
  }
}

#Preview("Dashboard") {
  ContentView(store: MonitorStore(daemonController: PreviewDaemonController()))
}

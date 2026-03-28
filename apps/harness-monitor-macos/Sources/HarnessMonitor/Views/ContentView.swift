import HarnessMonitorKit
import Observation
import SwiftUI

struct ContentView: View {
  @Bindable var store: MonitorStore
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
    NavigationSplitView {
      SidebarView(store: store)
        .navigationSplitViewColumnWidth(min: 300, ideal: 350)
    } content: {
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
      .navigationSplitViewColumnWidth(min: 600, ideal: 840)
    } detail: {
      InspectorColumnView(store: store)
        .navigationSplitViewColumnWidth(min: 320, ideal: 380)
    }
    .background(MonitorTheme.canvas.ignoresSafeArea())
    .searchable(text: $store.searchText, prompt: "Search sessions, projects, leaders")
    .navigationTitle("Harness Monitor")
    .toolbar {
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
    .sheet(isPresented: $showsPreferences) {
      PreferencesView(store: store)
        .frame(minWidth: 620, minHeight: 420)
    }
  }
}

#Preview("Dashboard") {
  ContentView(store: MonitorStore(daemonController: PreviewDaemonController()))
}

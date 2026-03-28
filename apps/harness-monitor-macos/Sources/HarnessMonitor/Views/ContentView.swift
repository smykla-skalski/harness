import HarnessMonitorKit
import Observation
import SwiftUI

struct ContentView: View {
  @Bindable var store: MonitorStore
  @Binding var themeMode: MonitorThemeMode
  @FocusState private var preferencesFocused: Bool
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
    GeometryReader { proxy in
      ZStack {
        MonitorTheme.canvas

        NavigationSplitView {
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
            ToolbarItemGroup(placement: .primaryAction) {
              Button(action: refresh) {
                HStack(spacing: 8) {
                  Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(
                      store.isRefreshing
                        ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                        : .easeOut(duration: 0.2),
                      value: store.isRefreshing
                    )
                  Text("Refresh")
                }
              }
              .keyboardShortcut("r", modifiers: [.command])
              .accessibilityIdentifier(MonitorAccessibility.refreshButton)

              Button(action: togglePreferences) {
                Label("Daemon", systemImage: "gearshape.2")
              }
              .accessibilityIdentifier(MonitorAccessibility.daemonPreferencesButton)
            }
          }
          .toolbarBackground(.regularMaterial, for: .windowToolbar)
          .navigationSplitViewColumnWidth(min: 600, ideal: 840)
        } detail: {
          InspectorColumnView(store: store)
            .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        }
        .navigationSplitViewStyle(.balanced)
        .blur(radius: showsPreferences ? 1.5 : 0)
        .animation(.easeInOut(duration: 0.18), value: showsPreferences)

        if showsPreferences {
          preferencesOverlay(in: proxy.size)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .zIndex(1)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onExitCommand {
      guard showsPreferences else {
        return
      }
      togglePreferences()
    }
  }

  private func refresh() {
    Task {
      await store.refresh()
    }
  }

  private func togglePreferences() {
    withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
      showsPreferences.toggle()
    }
  }

  @ViewBuilder
  private func preferencesOverlay(in size: CGSize) -> some View {
    ZStack {
      Button(action: togglePreferences) {
        Rectangle()
          .fill(MonitorTheme.overlayScrim)
          .contentShape(Rectangle())
          .ignoresSafeArea()
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(MonitorAccessibility.preferencesBackdrop)

      PreferencesView(store: store, themeMode: $themeMode, onDismiss: togglePreferences)
        .frame(
          width: min(max(700, size.width * 0.72), 960),
          height: min(max(520, size.height * 0.78), 820)
        )
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 32, style: .continuous)
            .stroke(MonitorTheme.panelBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MonitorAccessibility.preferencesRoot)
        .accessibilityFrameMarker(MonitorAccessibility.preferencesPanel)
        .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 18)
        .padding(24)
        .focused($preferencesFocused)
        .onAppear {
          preferencesFocused = true
        }
    }
  }
}

#Preview("Dashboard") {
  ContentView(
    store: MonitorStore(daemonController: PreviewDaemonController()),
    themeMode: .constant(.auto)
  )
}

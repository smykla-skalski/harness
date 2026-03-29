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

  private var selectedSessionSummary: SessionSummary? {
    store.selectedSessionSummary
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
            contentColumn
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .id(store.selectedSessionID ?? "board")
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
    .confirmationDialog(
      confirmationTitle,
      isPresented: confirmationBinding,
      titleVisibility: .visible,
    ) {
      switch store.pendingConfirmation {
      case .endSession:
        Button("End Session Now", role: .destructive) {
          Task { await store.confirmPendingAction() }
        }
      case .removeAgent:
        Button("Remove Agent Now", role: .destructive) {
          Task { await store.confirmPendingAction() }
        }
      case .removeLaunchAgent:
        Button("Remove Launch Agent Now", role: .destructive) {
          Task { await store.confirmPendingAction() }
        }
      case nil:
        EmptyView()
      }
      Button("Cancel", role: .cancel) {
        store.cancelConfirmation()
      }
    } message: {
      if !confirmationMessage.isEmpty {
        Text(confirmationMessage)
      }
    }
  }

  @ViewBuilder
  private var contentColumn: some View {
    if let detail = selectedDetail {
      SessionCockpitView(
        store: store,
        detail: detail,
        timeline: store.timeline
      )
      .transition(.opacity.combined(with: .move(edge: .trailing)))
    } else if let summary = selectedSessionSummary {
      sessionLoadingView(summary: summary)
        .transition(.opacity)
    } else {
      SessionsBoardView(store: store)
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }
  }

  private func refresh() {
    Task {
      await store.refresh()
    }
  }

  private var confirmationBinding: Binding<Bool> {
    Binding(
      get: { store.pendingConfirmation != nil },
      set: { isPresented in
        if !isPresented {
          store.cancelConfirmation()
        }
      }
    )
  }

  private var confirmationTitle: String {
    switch store.pendingConfirmation {
    case .endSession:
      "End Session?"
    case .removeAgent:
      "Remove Agent?"
    case .removeLaunchAgent:
      "Remove Launch Agent?"
    case nil:
      ""
    }
  }

  private var confirmationMessage: String {
    switch store.pendingConfirmation {
    case .endSession(let sessionID, let actorID):
      "This ends \(sessionID) using \(actorID). Active task work must already be closed."
    case .removeAgent(_, let agentID, let actorID):
      "This removes \(agentID) using \(actorID) and returns any active work to the queue."
    case .removeLaunchAgent:
      "This disables launchd residency for the harness daemon on this Mac."
    case nil:
      ""
    }
  }

  private func togglePreferences() {
    withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
      showsPreferences.toggle()
    }
  }

  private func sessionLoadingView(summary: SessionSummary) -> some View {
    MonitorColumnScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 10) {
                Circle()
                  .fill(statusColor(for: summary.status))
                  .frame(width: 12, height: 12)
                Text(summary.context)
                  .font(.system(size: 30, weight: .black, design: .serif))
                  .lineLimit(2)
              }
              Text("\(summary.projectName) • \(summary.sessionId)")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer()
          }

          MonitorLoadingStateView(title: "Loading live session detail")
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .monitorCard()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(MonitorTheme.ink)
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

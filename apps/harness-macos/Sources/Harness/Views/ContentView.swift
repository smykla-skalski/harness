import HarnessKit
import Observation
import SwiftUI

struct ContentView: View {
  @Bindable var store: HarnessStore
  let themeStyle: HarnessThemeStyle

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

  private var chromeAccessibilityValue: String {
    "style=\(themeStyle.rawValue), contentChrome=extended, inspectorChrome=extended"
  }

  var body: some View {
    NavigationSplitView {
      SidebarView(store: store, themeStyle: themeStyle)
        .navigationSplitViewColumnWidth(min: 300, ideal: 350)
    } content: {
      NavigationStack {
        SessionContentContainer(
          store: store,
          detail: selectedDetail,
          summary: selectedSessionSummary,
          timeline: store.timeline,
          themeStyle: themeStyle
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityFrameMarker("\(HarnessAccessibility.contentRoot).frame")
      }
      .navigationTitle("Harness")
      .toolbar {
        ToolbarItem(placement: .secondaryAction) {
          ConnectionToolbarBadge(metrics: store.connectionMetrics)
        }
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
          .accessibilityIdentifier(HarnessAccessibility.refreshButton)

          SettingsLink {
            Label("Settings", systemImage: "gearshape")
          }
          .accessibilityIdentifier(HarnessAccessibility.daemonPreferencesButton)
        }
      }
      .harnessExtendedChromeBackground {
        HarnessTheme.canvas(for: themeStyle)
      }
      .navigationSplitViewColumnWidth(min: 600, ideal: 840)
    } detail: {
      InspectorColumnView(store: store, themeStyle: themeStyle)
        .harnessExtendedChromeBackground {
          HarnessTheme.inspectorBackground(for: themeStyle)
        }
        .navigationSplitViewColumnWidth(min: 320, ideal: 380)
    }
    .toolbarRole(.editor)
    .navigationSplitViewStyle(.balanced)
    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.appChromeRoot)
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessAccessibility.appChromeState,
        text: chromeAccessibilityValue
      )
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
}

private struct SessionContentContainer: View {
  @Bindable var store: HarnessStore
  let detail: SessionDetail?
  let summary: SessionSummary?
  let timeline: [TimelineEntry]
  let themeStyle: HarnessThemeStyle

  var body: some View {
    ZStack {
      SessionsBoardView(store: store)
        .opacity(detail == nil && summary == nil ? 1 : 0)
        .allowsHitTesting(detail == nil && summary == nil)

      if let summary, detail == nil {
        SessionLoadingView(summary: summary)
          .transition(.opacity)
      }

      if let detail {
        SessionCockpitView(store: store, detail: detail, timeline: timeline)
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.18), value: detail?.session.sessionId)
    .animation(.easeInOut(duration: 0.18), value: summary?.sessionId)
  }
}

private struct SessionLoadingView: View {
  let summary: SessionSummary

  var body: some View {
    HarnessColumnScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 10) {
                Circle()
                  .fill(statusColor(for: summary.status))
                  .frame(width: 12, height: 12)
                  .accessibilityHidden(true)
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

          HarnessLoadingStateView(title: "Loading live session detail")
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .harnessCard()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(HarnessTheme.ink)
  }
}

#Preview("Dashboard") {
  ContentView(
    store: HarnessStore(daemonController: PreviewDaemonController()),
    themeStyle: .gradient
  )
}

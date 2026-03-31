import HarnessKit
import Observation
import SwiftUI

struct ContentView: View {
  @Bindable var store: HarnessStore
  @Environment(\.openSettings)
  private var openSettings
  @State private var showInspector = true

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
    [
      "contentChrome=native",
      "interactiveRows=plain",
      "controlGlass=system",
    ].joined(separator: ", ")
  }

  var body: some View {
    NavigationSplitView {
      SidebarView(store: store)
        .navigationSplitViewColumnWidth(min: 300, ideal: 350)
    } detail: {
      NavigationStack {
        VStack(spacing: 0) {
          if store.isShowingCachedData {
            CachedDataBanner()
          }
          SessionContentContainer(
            store: store,
            detail: selectedDetail,
            summary: selectedSessionSummary,
            timeline: store.timeline
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityFrameMarker("\(HarnessAccessibility.contentRoot).frame")
      }
      .navigationTitle("Harness")
      .toolbar {
        ToolbarItem(placement: .secondaryAction) {
          ConnectionToolbarBadge(metrics: store.connectionMetrics)
        }
        ToolbarItem(placement: .primaryAction) {
          RefreshToolbarButton(store: store)
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            showInspector.toggle()
          } label: {
            Label("Inspector", systemImage: "info.circle")
          }
          .keyboardShortcut("i", modifiers: [.command, .option])
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            openSettings()
          } label: {
            Label("Settings", systemImage: "gearshape")
          }
          .accessibilityIdentifier(HarnessAccessibility.daemonPreferencesButton)
        }
      }
      .inspector(isPresented: $showInspector) {
        InspectorColumnView(store: store)
          .inspectorColumnWidth(min: 320, ideal: 380, max: 500)
      }
    }
    .navigationSplitViewStyle(.prominentDetail)
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
      isPresented: $store.showConfirmation,
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

private struct RefreshToolbarButton: View {
  let store: HarnessStore
  @State private var isSpinning = false

  var body: some View {
    Button { Task { await store.refresh() } } label: {
      HStack(spacing: 8) {
        Image(systemName: "arrow.clockwise")
          .rotationEffect(.degrees(isSpinning ? 360 : 0))
          .animation(
            .linear(duration: 0.9).repeatForever(autoreverses: false),
            value: isSpinning
          )
        Text("Refresh")
      }
    }
    .keyboardShortcut("r", modifiers: [.command])
    .accessibilityIdentifier(HarnessAccessibility.refreshButton)
    .onChange(of: store.isRefreshing) { _, refreshing in
      if refreshing {
        isSpinning = true
      } else {
        withAnimation(.easeOut(duration: 0.4)) {
          isSpinning = false
        }
      }
    }
  }
}

private struct CachedDataBanner: View {
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "cloud.bolt")
        .font(.caption)
      Text("Showing cached data - daemon is offline")
        .font(.caption.weight(.medium))
      Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.orange.opacity(0.12))
    .foregroundStyle(.orange)
  }
}

private struct SessionContentContainer: View {
  let store: HarnessStore
  let detail: SessionDetail?
  let summary: SessionSummary?
  let timeline: [TimelineEntry]

  var body: some View {
    Group {
      if let detail {
        SessionCockpitView(store: store, detail: detail, timeline: timeline)
          .transition(.opacity)
      } else if let summary {
        SessionLoadingView(summary: summary)
          .transition(.opacity)
      } else {
        SessionsBoardView(store: store)
          .transition(.opacity)
      }
    }
    .animation(.spring(duration: 0.3), value: detail?.session.sessionId)
    .animation(.spring(duration: 0.3), value: summary?.sessionId)
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
                  .font(.system(size: 30, weight: .black, design: .rounded))
                  .lineLimit(2)
              }
              Text("\(summary.projectName) • \(summary.sessionId)")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer()
          }

          HarnessLoadingStateView(title: "Loading live session detail")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(HarnessTheme.ink)
  }
}

#Preview("Dashboard") {
  ContentView(store: HarnessStore(daemonController: PreviewDaemonController()))
}

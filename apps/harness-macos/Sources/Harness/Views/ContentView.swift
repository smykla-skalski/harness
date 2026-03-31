import HarnessKit
import Observation
import SwiftUI

struct InspectorVisibilityKey: FocusedValueKey {
  typealias Value = Binding<Bool>
}

extension FocusedValues {
  var inspectorVisibility: Binding<Bool>? {
    get { self[InspectorVisibilityKey.self] }
    set { self[InspectorVisibilityKey.self] = newValue }
  }
}

struct ContentView: View {
  @Bindable var store: HarnessStore
  @Environment(\.openSettings)
  private var openSettings
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @SceneStorage("showInspector")
  private var showInspector = true
  @SceneStorage("selectedSessionID")
  private var restoredSessionID: String?

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
      "controlGlass=none",
    ].joined(separator: ", ")
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SidebarView(store: store)
        .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 500)
    } detail: {
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
      .onKeyPress(.escape) {
        if store.inspectorSelection != .none {
          store.inspectorSelection = .none
          return .handled
        }
        return .ignored
      }
      .navigationTitle("Harness")
      .toolbar {
        ToolbarItem(placement: .status) {
          ConnectionToolbarBadge(metrics: store.connectionMetrics)
        }
        if !showInspector {
          ToolbarItem(placement: .primaryAction) {
            RefreshToolbarButton(store: store)
          }
          ToolbarItem(placement: .primaryAction) {
            Button {
              showInspector.toggle()
            } label: {
              Label("Inspector", systemImage: "info.circle")
            }
            .help("Toggle inspector (Cmd+Option+I)")
          }
          ToolbarItem(placement: .secondaryAction) {
            Button {
              openSettings()
            } label: {
              Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier(HarnessAccessibility.daemonPreferencesButton)
          }
        }
      }
    }
    .inspector(isPresented: $showInspector) {
      InspectorColumnView(store: store, isPresented: $showInspector)
        .inspectorColumnWidth(min: 320, ideal: 380, max: 500)
    }
    .navigationSplitViewStyle(.prominentDetail)
    .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .focusedSceneValue(\.inspectorVisibility, $showInspector)
    .onAppear {
      if let restoredSessionID, store.selectedSessionID == nil {
        Task { await store.selectSession(restoredSessionID) }
      }
    }
    .onChange(of: store.selectedSessionID) { _, newID in
      restoredSessionID = newID
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.appChromeRoot)
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessAccessibility.appChromeState,
        text: chromeAccessibilityValue
      )
    }
    .modifier(HarnessConfirmationDialogModifier(store: store))
    .onChange(of: store.connectionState) { _, newState in
      let message: String
      switch newState {
      case .online: message = "Connected to daemon"
      case .connecting: message = "Connecting to daemon"
      case .offline(let reason): message = "Disconnected: \(reason)"
      case .idle: return
      }
      AccessibilityNotification.Announcement(message).post()
    }
    .onChange(of: store.lastAction) { _, action in
      guard !action.isEmpty else { return }
      AccessibilityNotification.Announcement(action).post()
    }
    .task(id: store.lastAction) {
      guard !store.lastAction.isEmpty else { return }
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      store.lastAction = ""
    }
  }

}

private struct HarnessConfirmationDialogModifier: ViewModifier {
  @Bindable var store: HarnessStore

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        title,
        isPresented: $store.showConfirmation,
        titleVisibility: .visible
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
        if !message.isEmpty {
          Text(message)
        }
      }
  }

  private var title: String {
    switch store.pendingConfirmation {
    case .endSession: "End Session?"
    case .removeAgent: "Remove Agent?"
    case .removeLaunchAgent: "Remove Launch Agent?"
    case nil: ""
    }
  }

  private var message: String {
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

struct RefreshToolbarButton: View {
  let store: HarnessStore
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isSpinning = false

  var body: some View {
    Button { Task { await store.refresh() } } label: {
      HStack(spacing: HarnessTheme.itemSpacing) {
        Image(systemName: "arrow.clockwise")
          .rotationEffect(.degrees(reduceMotion ? 0 : (isSpinning ? 360 : 0)))
          .animation(
            reduceMotion
              ? nil
              : isSpinning
              ? .linear(duration: 0.9).repeatForever(autoreverses: false)
              : .easeOut(duration: 0.4),
            value: isSpinning
          )
        Text("Refresh")
      }
    }
    .accessibilityIdentifier(HarnessAccessibility.refreshButton)
    .onChange(of: store.isRefreshing) { _, refreshing in
      isSpinning = refreshing
    }
  }
}

private struct CachedDataBanner: View {
  var body: some View {
    HStack(spacing: HarnessTheme.itemSpacing) {
      Image(systemName: "cloud.bolt")
        .font(.caption)
        .accessibilityHidden(true)
      Text("Showing cached data - daemon is offline")
        .font(.caption.weight(.medium))
      Spacer()
    }
    .harnessCellPadding()
    .background(HarnessTheme.caution.opacity(0.12))
    .foregroundStyle(HarnessTheme.caution)
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
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
              HStack(spacing: HarnessTheme.itemSpacing) {
                Circle()
                  .fill(statusColor(for: summary.status))
                  .frame(width: 12, height: 12)
                  .accessibilityHidden(true)
                Text(summary.status.title)
                  .font(.caption.weight(.bold))
                  .foregroundStyle(statusColor(for: summary.status))
                Text(summary.context)
                  .font(.system(.largeTitle, design: .rounded, weight: .black))
                  .lineLimit(2)
              }
              Text("\(summary.projectName) • \(summary.sessionId)")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(HarnessTheme.secondaryInk)
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

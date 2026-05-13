import HarnessMonitorKit
import SwiftUI

struct SessionSidebar: View {
  let store: HarnessMonitorStore
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let sessionCodexRuns: [CodexRunSnapshot]
  let decisions: [Decision]
  let statusModel: SessionStatusSummaryModel
  let currentModifiers: EventModifiers
  @Bindable var state: SessionWindowStateCache
  @AppStorage(SessionWindowKeyboardShortcutOverlaySettings.storageKey)
  private var shortcutOverlaysEnabled = SessionWindowKeyboardShortcutOverlaySettings.defaultValue
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  @State private var selectionDispatcher = SessionSidebarSelectionDispatcher()
  @State private var listSelection: Set<SessionSelection> = []
  @State private var listSelectionSyncGeneration: UInt64 = 0
  @State private var mountsNativeSidebarList = false
  @State private var usesNativeListSelection = false

  init(
    store: HarnessMonitorStore,
    snapshot: HarnessMonitorSessionWindowSnapshot?,
    sessionCodexRuns: [CodexRunSnapshot],
    decisions: [Decision],
    statusModel: SessionStatusSummaryModel,
    currentModifiers: EventModifiers,
    state: SessionWindowStateCache
  ) {
    self.store = store
    self.snapshot = snapshot
    self.sessionCodexRuns = sessionCodexRuns
    self.decisions = decisions
    self.statusModel = statusModel
    self.currentModifiers = currentModifiers
    self.state = state
  }

  var body: some View {
    sidebarList
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SessionSidebarFooter(model: statusModel)
      }
  }

  private var shouldShowShortcutOverlays: Bool {
    shortcutOverlaysEnabled && !HarnessMonitorUITestEnvironment.disablesVisualOptions
  }

  var shouldRenderShortcutOverlays: Bool {
    shouldShowShortcutOverlays
      && [SessionCreateKind.agent, .task, .decision].contains {
        $0.createShortcut.isRevealed(by: currentModifiers)
      }
  }

  var sidebarSelectionDispatcher: SessionSidebarSelectionDispatcher {
    selectionDispatcher
  }

  var currentListSelection: Set<SessionSelection> {
    listSelection
  }

  var nativeListSelectionEnabled: Bool {
    usesNativeListSelection
  }

  func storeListSelection(_ selection: Set<SessionSelection>) {
    listSelection = selection
  }

  func bumpListSelectionSyncGeneration() -> UInt64 {
    listSelectionSyncGeneration &+= 1
    return listSelectionSyncGeneration
  }

  func matchesCurrentListSelectionSyncGeneration(_ generation: UInt64) -> Bool {
    generation == listSelectionSyncGeneration
  }

  private var sidebarList: some View {
    Group {
      if mountsNativeSidebarList {
        nativeSidebarList
      } else {
        pendingSidebarList
      }
    }
    .harnessFocusedSceneValue(\.harnessSessionSidebarSelection, selectionFocus)
    .onChange(of: state.selection) { _, _ in
      deferListSelectionSync(renderedSelectionSet())
    }
    .task(id: state.sessionID) {
      mountsNativeSidebarList = false
      usesNativeListSelection = false
      bindSelectionDispatcher()
      try? await Task.sleep(for: .milliseconds(1_100))
      guard !Task.isCancelled else { return }
      mountsNativeSidebarList = true
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled else { return }
      setListSelection(renderedSelectionSet())
      usesNativeListSelection = true
    }
    .onDisappear {
      selectionDispatcher.selectAll = nil
      selectionDispatcher.clearSelection = nil
      selectionDispatcher.deleteSelection = nil
    }
    .accessibilityValue(decisionSelectionAccessibilityValue)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowSidebar)
  }

  private var nativeSidebarList: some View {
    List(selection: nativeSelectionBinding) {
      routeSection
      agentsSection
      decisionsSection
      tasksSection
    }
    .coordinateSpace(name: SessionSidebarCreateButtonOverlayCoordinateSpace.name)
    .overlayPreferenceValue(
      SessionSidebarCreateButtonFramePreferenceKey.self,
      alignment: .topLeading
    ) { anchors in
      if shouldRenderShortcutOverlays {
        SessionSidebarCreateButtonShortcutOverlays(
          anchors: anchors,
          currentModifiers: currentModifiers
        )
      }
    }
    .listStyle(.sidebar)
    .transaction { transaction in
      transaction.animation = nil
      transaction.disablesAnimations = true
    }
    .environment(\.sidebarRowSize, sidebarRowSize)
    .onChange(of: decisions.map(\.id)) { _, ids in
      state.sidebarSelection.prune(kind: .decision, visibleIDs: Set(ids))
      pruneListSelection(kind: .decision, visibleIDs: Set(ids))
    }
    .onChange(of: (snapshot?.detail?.agents ?? []).map(\.agentId)) { _, ids in
      state.sidebarSelection.prune(kind: .agent, visibleIDs: Set(ids))
      pruneListSelection(kind: .agent, visibleIDs: Set(ids))
    }
    .onChange(of: (snapshot?.detail?.tasks ?? []).map(\.taskId)) { _, ids in
      state.sidebarSelection.prune(kind: .task, visibleIDs: Set(ids))
      pruneListSelection(kind: .task, visibleIDs: Set(ids))
    }
    .task(id: (snapshot?.detail?.agents ?? []).map(\.agentId)) {
      try? await Task.sleep(for: .milliseconds(650))
      guard !Task.isCancelled else { return }
      state.sidebarOrdering.reconcileAgentOrder(with: snapshot?.detail?.agents ?? [])
    }
    .onChange(of: state.lastPlainClick) { _, signal in
      collapseSelectionFromApplicationTap(signal)
    }
  }

  private var pendingSidebarList: some View {
    Color.clear
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityHidden(true)
  }

  private var sidebarRowSize: SidebarRowSize {
    switch HarnessMonitorTextSize.normalizedIndex(textSizeIndex) {
    case ..<HarnessMonitorTextSize.defaultIndex:
      .small
    case HarnessMonitorTextSize.defaultIndex..<HarnessMonitorTextSize.scales.count - 1:
      .medium
    default:
      .large
    }
  }
}

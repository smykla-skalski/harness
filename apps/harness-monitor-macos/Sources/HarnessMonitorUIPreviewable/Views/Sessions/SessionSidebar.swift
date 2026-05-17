import HarnessMonitorKit
import SwiftUI

struct SessionSidebar: View {
  let store: HarnessMonitorStore
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let sessionCodexRuns: [CodexRunSnapshot]
  let decisions: [Decision]
  let decisionIDs: [String]
  let statusModel: SessionStatusSummaryModel
  let currentModifiers: EventModifiers
  @Bindable var state: SessionWindowStateCache
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  @State private var selectionDispatcher = SessionSidebarSelectionDispatcher()
  @State private var listSelection: Set<SessionSelection> = []
  @State private var listSelectionSyncGeneration: UInt64 = 0
  @State private var showsDeferredSidebarSections = false
  @State private var usesNativeListSelection = false
  @State private var presentationWorker = SessionRouteListPresentationWorker()
  @State var cachedAgentPresentation = SessionAgentListPresentation.empty
  @State var cachedTaskPresentation = SessionTaskListPresentation.empty
  @State private var agentPresentationGeneration: UInt64 = 0
  @State private var taskPresentationGeneration: UInt64 = 0

  init(
    store: HarnessMonitorStore,
    snapshot: HarnessMonitorSessionWindowSnapshot?,
    sessionCodexRuns: [CodexRunSnapshot],
    decisions: [Decision],
    decisionIDs: [String],
    statusModel: SessionStatusSummaryModel,
    currentModifiers: EventModifiers,
    state: SessionWindowStateCache
  ) {
    self.store = store
    self.snapshot = snapshot
    self.sessionCodexRuns = sessionCodexRuns
    self.decisions = decisions
    self.decisionIDs = decisionIDs
    self.statusModel = statusModel
    self.currentModifiers = currentModifiers
    self.state = state
  }

  var body: some View {
    sidebarList
  }

  private var shouldShowShortcutOverlays: Bool {
    !HarnessMonitorUITestEnvironment.disablesVisualOptions
      && SessionWindowKeyboardShortcutOverlaySettings.read()
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

  var visibleAgentIDs: [String] {
    cachedAgentPresentation.agentIDs
  }

  var visibleTaskIDs: [String] {
    cachedTaskPresentation.taskIDs
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
    HarnessMonitorSidebar(
      accessibilityIdentifier: HarnessMonitorAccessibility.sessionWindowSidebar,
      accessibilityValue: decisionSelectionAccessibilityValue,
      statusModel: statusModel
    ) {
      nativeSidebarList
    }
    .harnessFocusedSceneValue(\.harnessSessionSidebarSelection, selectionFocus)
    .onChange(of: state.selection) { _, _ in
      deferListSelectionSync(renderedSelectionSet())
    }
    .task(id: state.sessionID) {
      showsDeferredSidebarSections = false
      usesNativeListSelection = false
      bindSelectionDispatcher()
      try? await Task.sleep(for: .milliseconds(1_100))
      guard !Task.isCancelled else { return }
      showsDeferredSidebarSections = true
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
  }

  private var agentPresentationInput: SessionAgentListPresentationInput {
    SessionAgentListPresentationInput(
      agents: snapshot?.detail?.agents ?? [],
      query: "",
      agentOrderIDs: state.sidebarOrdering.agentIDs
    )
  }

  private var taskPresentationInput: SessionTaskListPresentationInput {
    SessionTaskListPresentationInput(
      tasks: snapshot?.detail?.tasks ?? [],
      query: ""
    )
  }

  private var nativeSidebarList: some View {
    List(selection: nativeSelectionBinding) {
      sidebarRouteSection
      if showsDeferredSidebarSections {
        agentsSection
        decisionsSection
        tasksSection
      } else {
        pendingSidebarLoadingSection
      }
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
    .harnessMonitorSidebarListChrome(rowSize: sidebarRowSize)
    .task(id: agentPresentationInput) {
      await rebuildAgentPresentation(input: agentPresentationInput)
    }
    .task(id: taskPresentationInput) {
      await rebuildTaskPresentation(input: taskPresentationInput)
    }
    .onChange(of: decisionIDs) { _, ids in
      state.sidebarSelection.prune(kind: .decision, visibleIDs: Set(ids))
      pruneListSelection(kind: .decision, visibleIDs: Set(ids))
      bindSelectionDispatcher()
    }
    .onChange(of: visibleAgentIDs) { _, ids in
      state.sidebarSelection.prune(kind: .agent, visibleIDs: Set(ids))
      pruneListSelection(kind: .agent, visibleIDs: Set(ids))
      bindSelectionDispatcher()
    }
    .onChange(of: visibleTaskIDs) { _, ids in
      state.sidebarSelection.prune(kind: .task, visibleIDs: Set(ids))
      pruneListSelection(kind: .task, visibleIDs: Set(ids))
      bindSelectionDispatcher()
    }
    .task(id: visibleAgentIDs) {
      try? await Task.sleep(for: .milliseconds(650))
      guard !Task.isCancelled else { return }
      state.sidebarOrdering.reconcileAgentIDs(with: visibleAgentIDs)
    }
    .onChange(of: state.lastPlainClick) { _, signal in
      collapseSelectionFromApplicationTap(signal)
    }
  }

  @ViewBuilder private var sidebarRouteSection: some View {
    if nativeListSelectionEnabled {
      routeSection
    } else {
      pendingRouteSection
    }
  }

  private var pendingRouteSection: some View {
    ForEach(sidebarRoutes) { route in
      let selection = SessionSelection.route(route)
      let isSelected = displayedSelectionSet.contains(selection)
      Button {
        selectPendingRoute(route)
      } label: {
        SessionSidebarRow(
          title: route.title,
          systemImage: route.systemImage
        )
        .background {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.selection)
            .opacity(isSelected ? 0.18 : 0)
        }
        .harnessSelectionOutline(isSelected: isSelected, cornerRadius: 8)
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowRoute(route))
      .accessibilityValue(isSelected ? "selected" : "not selected")
      .contextMenu {
        unavailableRouteContextMenu
      }
    }
  }

  private var pendingSidebarLoadingSection: some View {
    Section {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        ProgressView()
          .controlSize(.small)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text("Loading session items")
            .scaledFont(.body.weight(.medium))
          Text("Agents, decisions, and tasks will appear shortly.")
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, HarnessMonitorTheme.spacingXS)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Loading session items")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowSidebarDeferredLoader)
    }
  }

  private var sidebarRowSize: SidebarRowSize {
    harnessSidebarRowSize(for: textSizeIndex)
  }

  @MainActor
  private func rebuildAgentPresentation(input: SessionAgentListPresentationInput) async {
    agentPresentationGeneration &+= 1
    let generation = agentPresentationGeneration
    let presentation = await presentationWorker.computeAgents(input: input)
    guard !Task.isCancelled, agentPresentationGeneration == generation else {
      return
    }
    if cachedAgentPresentation != presentation {
      cachedAgentPresentation = presentation
    }
  }

  @MainActor
  private func rebuildTaskPresentation(input: SessionTaskListPresentationInput) async {
    taskPresentationGeneration &+= 1
    let generation = taskPresentationGeneration
    let presentation = await presentationWorker.computeTasks(input: input)
    guard !Task.isCancelled, taskPresentationGeneration == generation else {
      return
    }
    if cachedTaskPresentation != presentation {
      cachedTaskPresentation = presentation
    }
  }
}

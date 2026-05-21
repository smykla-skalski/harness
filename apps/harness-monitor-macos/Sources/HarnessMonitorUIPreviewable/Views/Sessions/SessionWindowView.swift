import HarnessMonitorKit
import SwiftUI

public struct SessionWindowView: View {
  public let store: HarnessMonitorStore
  public let token: SessionWindowToken
  public let history: GlobalWindowNavigationHistory
  @State var stateCacheStorage: SessionWindowStateCache
  @Environment(\.dismiss)
  var dismiss
  @Environment(\.openWindow)
  var openWindow
  @Environment(\.accessibilityReduceMotion)
  var reduceMotion: Bool
  @SceneStorage("session.route")
  var persistedRoute: SessionWindowRoute = .overview
  @SceneStorage("session.decisionID")
  var persistedDecisionID: String = ""
  @SceneStorage("session.decisionFilters.query")
  var persistedDecisionQuery = ""
  @SceneStorage("session.decision.detail-tab")
  var persistedDecisionDetailTabRawStorage = DecisionDetailTab.context.rawValue
  @SceneStorage("session.focusMode")
  var focusModeStorage = false
  @SceneStorage("session.inspector.visible")
  var inspectorVisibleStorage = false
  @SceneStorage("session.inspector.preferred")
  var inspectorPreferredStorage = false
  @SceneStorage("session.inspector.width")
  var inspectorWidthStorage = 280.0
  @SceneStorage("session.sidebarWidth")
  var sidebarWidthStorage = 200.0
  @SceneStorage("session.content-detail.width")
  var contentColumnWidthStorage = SessionContentDetailSplitLayout.defaultContentWidth
  @AccessibilityFocusState var primaryContentAccessibilityFocused: Bool
  @AppStorage(HarnessMonitorMCPSettingsDefaults.registryHostEnabledKey)
  var mcpRegistryHostEnabled = HarnessMonitorMCPSettingsDefaults
    .registryHostEnabledDefault
  @State var snapshotStorage: HarnessMonitorSessionWindowSnapshot?
  @State var isLoadingStorage = false
  @State var didLoadSnapshotStorage = false
  @State var detailColumnWidthStorage: CGFloat = 0
  @State var liveInspectorWidthStorage: Double?
  @State var liveContentColumnWidthStorage: Double?
  @State var perfContentDividerWidthStorage: Double?
  @State var decisionCacheStorage = SessionWindowDecisionCacheStorage()
  @State var currentModifiers: EventModifiers = []
  @State var policyCanvasViewModelStorage: PolicyCanvasViewModel
  @State var startupSearchParticipationEnabledStorage =
    HarnessMonitorUITestEnvironment.isEnabled
  @State var handledHistoryRestoreRequestID = 0

  @MainActor
  public init(
    store: HarnessMonitorStore,
    token: SessionWindowToken,
    initialRoute: SessionWindowRoute? = nil,
    history: GlobalWindowNavigationHistory? = nil
  ) {
    self.store = store
    self.token = token
    self.history = history ?? GlobalWindowNavigationHistory(store: store)
    _stateCacheStorage = State(
      wrappedValue: SessionWindowStateCache(
        sessionID: token.sessionID,
        selection: .route(initialRoute ?? .overview)
      )
    )
    _policyCanvasViewModelStorage = State(
      wrappedValue: PolicyCanvasViewModel.liveStartupState(
        document: store.contentUI.dashboard.taskBoardPolicyPipeline,
        simulation: store.contentUI.dashboard.taskBoardPolicySimulation,
        audit: store.contentUI.dashboard.taskBoardPolicyAudit
      )
    )
  }
  var stateCache: SessionWindowStateCache {
    stateCacheStorage
  }
  var snapshot: HarnessMonitorSessionWindowSnapshot? {
    get { snapshotStorage }
    nonmutating set { snapshotStorage = newValue }
  }

  var isLoading: Bool {
    get { isLoadingStorage }
    nonmutating set { isLoadingStorage = newValue }
  }

  var didLoadSnapshot: Bool {
    get { didLoadSnapshotStorage }
    nonmutating set { didLoadSnapshotStorage = newValue }
  }

  var detailColumnWidth: CGFloat {
    get { detailColumnWidthStorage }
    nonmutating set { detailColumnWidthStorage = newValue }
  }

  var focusMode: Bool {
    get { focusModeStorage }
    nonmutating set { focusModeStorage = newValue }
  }

  var focusModeBinding: Binding<Bool> {
    Binding(
      get: { focusModeStorage },
      set: { if focusModeStorage != $0 { focusModeStorage = $0 } }
    )
  }

  var inspectorVisible: Bool {
    get { inspectorVisibleStorage }
    nonmutating set { inspectorVisibleStorage = newValue }
  }

  var inspectorVisibleBinding: Binding<Bool> {
    Binding(
      get: { inspectorVisibleStorage },
      set: { if inspectorVisibleStorage != $0 { inspectorVisibleStorage = $0 } }
    )
  }

  var inspectorPreferred: Bool {
    get { inspectorPreferredStorage }
    nonmutating set { inspectorPreferredStorage = newValue }
  }

  var inspectorPreferredBinding: Binding<Bool> {
    Binding(
      get: { inspectorPreferredStorage },
      set: { if inspectorPreferredStorage != $0 { inspectorPreferredStorage = $0 } }
    )
  }

  var storedInspectorWidth: Double {
    get { inspectorWidthStorage }
    nonmutating set { inspectorWidthStorage = newValue }
  }

  var liveInspectorWidthDraft: Double? {
    get { liveInspectorWidthStorage }
    nonmutating set { liveInspectorWidthStorage = newValue }
  }

  var storedContentColumnWidth: Double {
    get { contentColumnWidthStorage }
    nonmutating set { contentColumnWidthStorage = newValue }
  }

  var liveContentColumnWidthDraft: Double? {
    get { liveContentColumnWidthStorage }
    nonmutating set { liveContentColumnWidthStorage = newValue }
  }

  var perfContentDividerWidth: Double? {
    get { perfContentDividerWidthStorage }
    nonmutating set { perfContentDividerWidthStorage = newValue }
  }

  var perfContentDividerWidthBinding: Binding<Double?> {
    Binding(
      get: { perfContentDividerWidth },
      set: { perfContentDividerWidth = $0 }
    )
  }

  var sidebarWidth: Double {
    get { sidebarWidthStorage }
    nonmutating set { sidebarWidthStorage = newValue }
  }

  var presentedModifiers: EventModifiers {
    currentModifiers
  }

  var policyCanvasViewModel: PolicyCanvasViewModel {
    policyCanvasViewModelStorage
  }

  var isStartupSearchParticipationEnabled: Bool {
    get { startupSearchParticipationEnabledStorage }
    nonmutating set { startupSearchParticipationEnabledStorage = newValue }
  }

  func enableStartupSearchParticipation() {
    guard !isStartupSearchParticipationEnabled else { return }
    isStartupSearchParticipationEnabled = true
  }

  var decisionDetailTab: DecisionDetailTab {
    get { DecisionDetailTab(rawValue: persistedDecisionDetailTabRawStorage) ?? .context }
    nonmutating set { persistedDecisionDetailTabRawStorage = newValue.rawValue }
  }

  var decisionDetailTabBinding: Binding<DecisionDetailTab> {
    Binding(
      get: { decisionDetailTab },
      set: { if decisionDetailTab != $0 { decisionDetailTab = $0 } }
    )
  }

  var allSessionDecisionsCache: [Decision] {
    get { decisionCacheStorage.allSessionDecisions }
    nonmutating set { decisionCacheStorage.allSessionDecisions = newValue }
  }

  var allSessionDecisionPresentationItemsCache: [DecisionPresentationSnapshot] {
    get { decisionCacheStorage.allSessionDecisionPresentationItems }
    nonmutating set { decisionCacheStorage.allSessionDecisionPresentationItems = newValue }
  }

  var allSessionDecisionSearchProjectionsCache: [DecisionSearchProjection] {
    get { decisionCacheStorage.allSessionDecisionSearchProjections }
    nonmutating set { decisionCacheStorage.allSessionDecisionSearchProjections = newValue }
  }

  var matchingDecisionsCache: [Decision] {
    get { decisionCacheStorage.matchingDecisions }
    nonmutating set { decisionCacheStorage.matchingDecisions = newValue }
  }

  var matchingDecisionPresentationItemsCache: [DecisionPresentationSnapshot] {
    get { decisionCacheStorage.matchingDecisionPresentationItems }
    nonmutating set { decisionCacheStorage.matchingDecisionPresentationItems = newValue }
  }

  var allSessionDecisionIDsCache: Set<String> {
    get { decisionCacheStorage.allSessionDecisionIDs }
    nonmutating set { decisionCacheStorage.allSessionDecisionIDs = newValue }
  }

  var allSessionDecisionIDsInOrderCache: [String] {
    get { decisionCacheStorage.allSessionDecisionIDsInOrder }
    nonmutating set { decisionCacheStorage.allSessionDecisionIDsInOrder = newValue }
  }

  var matchingDecisionIDsCache: Set<String> {
    get { decisionCacheStorage.matchingDecisionIDs }
    nonmutating set { decisionCacheStorage.matchingDecisionIDs = newValue }
  }

  var matchingDecisionIDsInOrderCache: [String] {
    get { decisionCacheStorage.matchingDecisionIDsInOrder }
    nonmutating set { decisionCacheStorage.matchingDecisionIDsInOrder = newValue }
  }

  var detailRenderedSelection: SessionSelection? {
    get { decisionCacheStorage.detailRenderedSelection }
    nonmutating set { decisionCacheStorage.detailRenderedSelection = newValue }
  }

  var contentRenderedRoute: SessionWindowRoute? {
    get { decisionCacheStorage.contentRenderedRoute }
    nonmutating set { decisionCacheStorage.contentRenderedRoute = newValue }
  }

  var route: SessionWindowRoute {
    route(for: stateCache.selection)
  }

  var windowNavigationState: WindowNavigationState {
    let navigationState = WindowNavigationState(
      canGoBack: history.canGoBack,
      canGoForward: history.canGoForward
    )
    navigationState.setHandlers(
      back: { history.navigateBack() },
      forward: { history.navigateForward() }
    )
    return navigationState
  }

  var renderedRoute: SessionWindowRoute {
    contentRenderedRoute ?? route
  }

  public var body: some View {
    ZStack {
      bodyContent
      if !HarnessMonitorPerfIsolation.disablesSearchHost {
        sessionSearchHost
      }
    }
    .toolbar { sessionToolbar }
    .background {
      sessionWindowBackgroundAnchors(currentModifiers: $currentModifiers)
    }
  }

  var bodyContent: some View {
    sessionWindowFocusedValues(
      sessionWindowDecisionFilterPersistence(
        sessionWindowSelectionObservers(
          sessionWindowLifecycleModifiers(sessionWindowSurface)
        )
      )
    )
    .task(id: history.pendingSessionRestoreRequest) {
      await applyPendingHistoryRestoreIfNeeded()
    }
    .task {
      history.installNavigator(openWindow: openWindow)
      history.installSessionStateIfNeeded(
        sessionID: token.sessionID,
        selection: stateCache.selection
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityFocused($primaryContentAccessibilityFocused)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowShell)
  }

  @ViewBuilder var sessionWindowSurface: some View {
    if isUnknownSession {
      unknownSessionContent
    } else {
      sessionSurface
    }
  }
}

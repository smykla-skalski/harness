import HarnessMonitorKit
import SwiftUI

struct SidebarView: View {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice
  let projection: HarnessMonitorStore.SessionProjectionSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice
  let sidebarUI: HarnessMonitorStore.SidebarUISlice
  let canPresentSearch: Bool
  let interactionRelay: ContentInteractionRelay
  @Environment(\.harnessDateTimeConfiguration)
  var dateTimeConfiguration
  @Environment(\.fontScale)
  var fontScale

  @State private var collapsedCheckoutKeys: Set<String> = []

  var body: some View {
    SidebarSearchHost(
      store: store,
      controls: controls,
      projection: projection,
      searchResults: searchResults,
      sidebarUI: sidebarUI,
      canPresentSearch: canPresentSearch,
      interactionRelay: interactionRelay,
      dateTimeConfiguration: dateTimeConfiguration,
      fontScale: fontScale,
      collapsedCheckoutKeys: collapsedCheckoutKeys,
      setCheckoutCollapsed: setCheckoutCollapsed
    )
  }

  func setCheckoutCollapsed(
    checkoutKey: String,
    isCollapsed: Bool
  ) {
    if isCollapsed {
      collapsedCheckoutKeys.insert(checkoutKey)
    } else {
      collapsedCheckoutKeys.remove(checkoutKey)
    }
  }
}

struct SidebarSessionListColumn: View {
  let store: HarnessMonitorStore
  let controls: HarnessMonitorStore.SessionControlsSlice
  let projection: HarnessMonitorStore.SessionProjectionSlice
  let searchResults: HarnessMonitorStore.SessionSearchResultsSlice
  let sidebarUI: HarnessMonitorStore.SidebarUISlice
  let interactionRelay: ContentInteractionRelay
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let fontScale: CGFloat
  let collapsedCheckoutKeys: Set<String>
  let setCheckoutCollapsed: (String, Bool) -> Void
  @State private var localSelection: Set<String>
  @State private var currentModifiers: EventModifiers = []
  @State private var trailingWhitespaceBoundaryMaxY: CGFloat = 0

  init(
    store: HarnessMonitorStore,
    controls: HarnessMonitorStore.SessionControlsSlice,
    projection: HarnessMonitorStore.SessionProjectionSlice,
    searchResults: HarnessMonitorStore.SessionSearchResultsSlice,
    sidebarUI: HarnessMonitorStore.SidebarUISlice,
    interactionRelay: ContentInteractionRelay,
    dateTimeConfiguration: HarnessMonitorDateTimeConfiguration,
    fontScale: CGFloat,
    collapsedCheckoutKeys: Set<String>,
    setCheckoutCollapsed: @escaping (String, Bool) -> Void
  ) {
    self.store = store
    self.controls = controls
    self.projection = projection
    self.searchResults = searchResults
    self.sidebarUI = sidebarUI
    self.interactionRelay = interactionRelay
    self.dateTimeConfiguration = dateTimeConfiguration
    self.fontScale = fontScale
    self.collapsedCheckoutKeys = collapsedCheckoutKeys
    self.setCheckoutCollapsed = setCheckoutCollapsed
    _localSelection = State(
      initialValue: SidebarSessionListSelectionSync.selection(for: sidebarUI.selectedSessionID)
    )
  }

  private var visibleSessionIDs: Set<String> {
    Set(searchResults.visibleSessionIDs)
  }

  private var renderedSidebarSelection: Set<String> {
    SidebarSessionListSelectionSync.renderedSelection(
      from: localSelection,
      visibleSessionIDs: visibleSessionIDs
    )
  }

  private var sidebarSelection: Binding<Set<String>> {
    Binding(
      get: { renderedSidebarSelection },
      set: { newValue in
        let change = SidebarSessionListSelectionSync.resolve(
          previousSelection: localSelection,
          newRenderedSelection: newValue,
          visibleSessionIDs: visibleSessionIDs,
          storeSelectedSessionID: sidebarUI.selectedSessionID
        )
        HarnessMonitorUITestTrace.record(
          component: "sidebar.selection-binding",
          event: "set",
          details: [
            "new_count": "\(newValue.count)",
            "new_ids": newValue.sorted().joined(separator: ","),
            "sidebar_selected_session_id": sidebarUI.selectedSessionID ?? "nil",
            "rendered_selection_ids": renderedSidebarSelection.sorted().joined(separator: ","),
          ]
        )
        applySelectionChange(change)
      }
    )
  }

  private var renderState: SidebarSessionListRenderState {
    SidebarSessionListRenderState(
      sessionCatalog: store.sessionIndex.catalog,
      projectionGroups: projection.groupedSessions,
      searchPresentation: searchResults.presentationState,
      searchVisibleSessionIDs: searchResults.visibleSessionIDs,
      selectedSessionIDs: renderedSidebarSelection,
      bookmarkedSessionIDs: sidebarUI.bookmarkedSessionIds,
      isPersistenceAvailable: sidebarUI.isPersistenceAvailable,
      dateTimeConfiguration: dateTimeConfiguration,
      fontScale: fontScale,
      collapsedCheckoutKeys: collapsedCheckoutKeys
    )
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        Color.clear.accessibilityHidden(true)
        List(selection: sidebarSelection) {
          SidebarSessionListContent(
            store: store,
            renderState: renderState,
            activateSessionRow: activateSessionRow,
            collapseSelectionToRow: collapseSelectionToRow,
            toggleBookmark: { sessionID, projectID in
              store.toggleBookmark(sessionId: sessionID, projectId: projectID)
            },
            setCheckoutCollapsed: setCheckoutCollapsed
          )
        }
        trailingWhitespaceTapLayer(containerSize: proxy.size)
      }
    }
    .contentShape(Rectangle())
    .coordinateSpace(name: SidebarSessionListInteractionMetrics.coordinateSpaceName)
    .onPreferenceChange(SidebarSessionListTrailingWhitespaceBoundaryPreferenceKey.self) {
      trailingWhitespaceBoundaryMaxY = $0
    }
    .onModifierKeysChanged { _, newModifiers in
      if currentModifiers != newModifiers {
        currentModifiers = newModifiers
      }
    }
    .onChange(of: sidebarUI.selectedSessionID, initial: true) { _, newValue in
      syncSelectionFromStore(newValue)
    }
    .onChange(of: interactionRelay.plainClickSignal) { _, signal in
      collapseSelectionFromApplicationTap(signal)
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarSessionListContent)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.sidebarSessionListState,
      label: renderState.groupedStateAccessibilityLabel
    )
  }

  private func activateSessionRow(_ sessionID: String) {
    let change = SidebarSessionListSelectionSync.semanticActivation(
      sessionID: sessionID,
      storeSelectedSessionID: sidebarUI.selectedSessionID
    )
    HarnessMonitorUITestTrace.record(
      component: "sidebar.selection-semantic-press",
      event: "activate",
      details: [
        "session_id": sessionID,
        "previous_ids": localSelection.sorted().joined(separator: ","),
        "store_selected_session_id": sidebarUI.selectedSessionID ?? "nil",
      ]
    )
    applySelectionChange(change)
  }

  private func collapseSelectionToRow(_ sessionID: String) {
    guard renderedSidebarSelection.count > 1 else {
      return
    }
    let blockingModifiers = currentModifiers.intersection([
      .command, .shift, .control, .option,
    ])
    guard blockingModifiers.isEmpty else {
      return
    }
    applySelectionChange(
      SidebarSessionListSelectionSync.explicitSingleSelection(
        sessionID: sessionID,
        storeSelectedSessionID: sidebarUI.selectedSessionID
      )
    )
  }

  private func collapseSelectionFromApplicationTap(_ signal: ContentPlainClickSignal) {
    guard renderedSidebarSelection.count > 1 else {
      return
    }
    let blockingModifiers = signal.modifiers.intersection([
      .command, .shift, .control, .option,
    ])
    guard blockingModifiers.isEmpty else {
      return
    }
    if let sessionID = sidebarUI.selectedSessionID,
      renderedSidebarSelection.contains(sessionID)
    {
      applySelectionChange(
        SidebarSessionListSelectionSync.explicitSingleSelection(
          sessionID: sessionID,
          storeSelectedSessionID: sidebarUI.selectedSessionID
        )
      )
    } else {
      collapseSelectionFromPlainBackground()
    }
  }

  private func collapseSelectionFromPlainBackground() {
    guard renderedSidebarSelection.count > 1 else {
      return
    }
    let change =
      if let sessionID = sidebarUI.selectedSessionID,
        renderedSidebarSelection.contains(sessionID)
      {
        SidebarSessionListSelectionSync.explicitSingleSelection(
          sessionID: sessionID,
          storeSelectedSessionID: sidebarUI.selectedSessionID
        )
      } else {
        SidebarSessionListSelectionChange(
          nextSelection: [],
          storeSelection: .cleared
        )
      }
    applySelectionChange(change)
  }

  @ViewBuilder
  private func trailingWhitespaceTapLayer(containerSize: CGSize) -> some View {
    let whitespaceHeight = max(0, containerSize.height - trailingWhitespaceBoundaryMaxY)

    if renderedSidebarSelection.count > 1,
      trailingWhitespaceBoundaryMaxY > 0,
      whitespaceHeight > 1
    {
      Color.clear
        .contentShape(Rectangle())
        .frame(width: containerSize.width, height: whitespaceHeight)
        .offset(y: trailingWhitespaceBoundaryMaxY)
        .gesture(
          SpatialTapGesture().onEnded { _ in
            collapseSelectionFromSidebarWhitespaceTap()
          }
        )
        .accessibilityHidden(true)
    }
  }

  private func collapseSelectionFromSidebarWhitespaceTap() {
    let blockingModifiers = currentModifiers.intersection([
      .command, .shift, .control, .option,
    ])
    guard blockingModifiers.isEmpty else {
      return
    }
    collapseSelectionFromPlainBackground()
  }

  private func syncSelectionFromStore(_ sessionID: String?) {
    let nextSelection = SidebarSessionListSelectionSync.selection(for: sessionID)
    guard localSelection != nextSelection else {
      return
    }
    HarnessMonitorUITestTrace.record(
      component: "sidebar.selection-store-sync",
      event: "applied",
      details: [
        "from_ids": localSelection.sorted().joined(separator: ","),
        "to_ids": nextSelection.sorted().joined(separator: ","),
        "store_selected_session_id": sessionID ?? "nil",
      ]
    )
    localSelection = nextSelection
  }

  private func applySelectionChange(_ change: SidebarSessionListSelectionChange) {
    localSelection = change.nextSelection
    switch change.storeSelection {
    case .unchanged:
      return
    case .cleared:
      if sidebarUI.selectedSessionID != nil {
        store.selectSessionFromList(nil)
      }
    case .selected(let sessionID):
      store.selectSessionFromList(sessionID)
    }
  }
}

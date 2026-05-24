import HarnessMonitorKit
import SwiftUI

extension SessionSidebar {
  var decisionSelectionAccessibilityValue: Text {
    if let anchor = state.sidebarSelection.anchor {
      let count = state.sidebarSelection.count(of: anchor.kind)
      let visible = visibleCount(for: anchor.kind)
      return Text("\(count) of \(visible) \(anchor.kind.pluralNoun) selected")
    }
    let displayedSelection = displayedSelectionSet
    if displayedSelection.count > 1 {
      return Text("\(displayedSelection.count) items selected")
    }
    return Text("No multi-selection")
  }

  var nativeSelectionBinding: Binding<Set<SessionSelection>>? {
    // Mount the session sidebar without `List(selection:)` during the first
    // window-animation turn. Attaching the binding once the window has settled
    // keeps native multi-selection while avoiding AppKit's reentrant table
    // delegate warning during initial `NSTableView` construction.
    nativeListSelectionEnabled ? selectionBinding : nil
  }

  var displayedSelectionSet: Set<SessionSelection> {
    currentListSelection.isEmpty ? renderedSelectionSet() : currentListSelection
  }

  func renderedSelectionSet() -> Set<SessionSelection> {
    var set: Set<SessionSelection> = []
    set.insert(state.selection)
    let sid = state.sessionID
    for id in state.sidebarSelection.selectedAgentIDs {
      set.insert(.agent(sessionID: sid, agentID: id))
    }
    for id in state.sidebarSelection.selectedTaskIDs {
      set.insert(.task(sessionID: sid, taskID: id))
    }
    for id in state.sidebarSelection.selectedDecisionIDs {
      set.insert(.decision(sessionID: sid, decisionID: id))
    }
    return set
  }

  func pruneListSelection(
    kind: SessionSidebarSelectionKind,
    visibleIDs: Set<String>
  ) {
    let current = displayedSelectionSet
    let pruned = current.filter { selection in
      guard multiSelectKind(of: selection) == kind else { return true }
      guard let selectionID = multiSelectID(of: selection) else { return true }
      return visibleIDs.contains(selectionID)
    }
    if pruned != current {
      setListSelection(pruned)
    }
  }

  /// Native `List(selection: Set<>)` does not collapse a multi-selection when the
  /// user plain-clicks a row that is already in the set; the selection is left
  /// alone. Mirror the legacy app's collapse-on-tap so plain clicks act like a
  /// "back to single-select on this row" intent.
  func collapseToRowFromPlainTap(_ selection: SessionSelection) {
    let blocking = currentModifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    state.sidebarSelection.clear()
    state.selectFromSidebar(selection)
    setListSelection([selection])
  }

  /// Plain tap anywhere in the SessionWindow (outside the sidebar list).
  /// Mirrors legacy `collapseSelectionFromApplicationTap`: bail on modifiers,
  /// otherwise clear the multi-extension and leave primary intact.
  func collapseSelectionFromApplicationTap(_ signal: SessionPlainClickSignal) {
    let blocking = signal.modifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    state.sidebarSelection.clear()
    setListSelection([state.selection])
  }

  func selectPendingRoute(_ route: SessionWindowRoute) {
    let selection = SessionSelection.route(route)
    state.sidebarSelection.clear()
    state.selectFromSidebar(selection)
    setListSelection([selection])
  }

  var hasActiveMultiSelection: Bool {
    state.sidebarSelection.hasActiveMultiSelection
  }

  func setListSelection(_ selection: Set<SessionSelection>) {
    if currentListSelection != selection {
      storeListSelection(selection)
    }
    state.sidebarSelection.syncRenderedSelectionCount(selection.count)
  }

  func deferListSelectionSync(_ selection: Set<SessionSelection>) {
    let generation = bumpListSelectionSyncGeneration()
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled, matchesCurrentListSelectionSyncGeneration(generation) else {
        return
      }
      setListSelection(selection)
    }
  }

  func visibleCount(for kind: SessionSidebarSelectionKind) -> Int {
    switch kind {
    case .agent: visibleAgentIDs.count
    case .task: visibleTaskIDs.count
    case .decision: decisionIDs.count
    }
  }

  private var selectionBinding: Binding<Set<SessionSelection>> {
    Binding(
      get: { currentListSelection },
      set: { applyListSelection($0) }
    )
  }

  private func applyListSelection(_ new: Set<SessionSelection>) {
    let old = displayedSelectionSet
    guard new != old else { return }
    setListSelection(new)

    if new.isEmpty {
      state.sidebarSelection.clear()
      return
    }

    let added = new.subtracting(old)
    let pivot = added.first ?? new.first
    guard let pivotItem = pivot else { return }

    if new.count == 1 {
      state.sidebarSelection.clear()
      state.selectFromSidebar(pivotItem)
      return
    }

    guard let actionableSelection = actionableMultiSelection(from: new) else {
      state.sidebarSelection.clear()
      return
    }

    let anchorID = multiSelectID(of: pivotItem) ?? state.sidebarSelection.anchor?.id
    state.sidebarSelection.applyChange(
      kind: actionableSelection.kind,
      selectedIDs: actionableSelection.ids,
      anchorID: anchorID
    )
    state.sidebarAnnouncer.announce(
      kind: actionableSelection.kind,
      count: actionableSelection.ids.count,
      visibleCount: visibleCount(for: actionableSelection.kind)
    )
  }

  private func actionableMultiSelection(
    from selection: Set<SessionSelection>
  ) -> (kind: SessionSidebarSelectionKind, ids: Set<String>)? {
    let kinds = Set(selection.compactMap { multiSelectKind(of: $0) })
    guard kinds.count == 1, let kind = kinds.first else { return nil }
    let ids = Set(selection.compactMap { multiSelectID(of: $0) })
    guard ids.count == selection.count else { return nil }
    return (kind, ids)
  }

  private func multiSelectKind(of selection: SessionSelection) -> SessionSidebarSelectionKind? {
    switch selection {
    case .agent: .agent
    case .task: .task
    case .decision: .decision
    case .route, .codexRun, .openRouterRun, .create: nil
    }
  }

  private func multiSelectID(of selection: SessionSelection) -> String? {
    switch selection {
    case .agent(_, let id): id
    case .task(_, let id): id
    case .decision(_, let id): id
    case .route, .codexRun, .openRouterRun, .create: nil
    }
  }
}

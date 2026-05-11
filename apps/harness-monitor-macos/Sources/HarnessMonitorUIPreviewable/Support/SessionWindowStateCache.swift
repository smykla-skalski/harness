import HarnessMonitorKit
import Observation
import SwiftUI

public struct SessionPlainClickSignal: Equatable, Sendable {
  public var generation: UInt64 = 0
  public var modifiers: EventModifiers = []
}

@MainActor
@Observable
public final class SessionWindowStateCache {
  public let sessionID: String
  public let appSearchIndex: AppSearchIndex
  public let appSearchModel: AppSearchModel
  public var selection: SessionSelection
  public var sidebarOrdering = SessionSidebarOrderingState()
  public var sidebarSelection = SessionSidebarSelectionState()
  public var sectionState = SessionWindowSectionState()
  var agentCreateCatalog = SessionWindowAgentCreateCatalogState()
  var manualLaunchSelectionKinds: Set<SessionCreateKind> = []
  public var decisionRuntime = SessionDecisionRuntime()
  public var decisionFilters = SessionDecisionFilterState()
  public var sidebarAnnouncer = SessionSidebarMultiSelectAnnouncer()
  public var navigationHistory = SessionWindowNavigationHistory()
  public var attention = SessionAttentionState()
  public var lastTaskDecisionLink: SessionTaskDecisionLink?
  public private(set) var selectionSource: SessionSelectionSource = .programmatic
  public private(set) var agentComposerFocusRequestID = 0
  /// Bumped by the SessionWindow root on every tap anywhere in the window.
  /// Sidebar watches this to collapse multi-selection when the user taps
  /// outside the selected rows. Carries the modifiers held at click time so
  /// the receiver can bail on cmd/shift/etc.-clicks. Mirrors legacy
  /// ContentInteractionRelay.plainClickSignal.
  public private(set) var lastPlainClick = SessionPlainClickSignal()

  public func recordPlainTap(modifiers: EventModifiers) {
    lastPlainClick = SessionPlainClickSignal(
      generation: lastPlainClick.generation &+ 1,
      modifiers: modifiers
    )
  }

  public init(sessionID: String, selection: SessionSelection = .route(.overview)) {
    self.sessionID = sessionID
    self.selection = selection
    let index = AppSearchIndex()
    appSearchIndex = index
    appSearchModel = AppSearchModel(index: index)
  }

  public func selectRoute(_ route: SessionWindowRoute) {
    updateSelection(.route(route), source: .programmatic)
  }

  public func selectAgent(_ agentID: String) {
    updateSelection(.agent(sessionID: sessionID, agentID: agentID), source: .programmatic)
  }

  public func selectDecision(_ decisionID: String) {
    updateSelection(.decision(sessionID: sessionID, decisionID: decisionID), source: .programmatic)
  }

  public func autoSelectDecision(_ decisionID: String) {
    updateSelection(
      .decision(sessionID: sessionID, decisionID: decisionID),
      source: .programmatic,
      rememberCurrentSelection: false,
      recordHistory: false
    )
  }

  public func setRouteDecisionID(_ decisionID: String?) {
    sectionState.decisionID = decisionID
  }

  public func setRouteAgentID(_ agentID: String?) {
    sectionState.agentID = agentID
  }

  public func selectTask(_ taskID: String) {
    updateSelection(.task(sessionID: sessionID, taskID: taskID), source: .programmatic)
  }

  public func selectCreate(_ kind: SessionCreateKind) {
    let draft: SessionCreateDraft
    if let existing = sectionState.createDrafts[kind] {
      draft = existing
    } else {
      let freshDraft = Self.freshCreateDraft(kind: kind, sessionID: sessionID)
      sectionState.createDrafts[kind] = freshDraft
      setDidPickCreateLaunchSelectionManually(false, for: kind)
      draft = freshDraft
    }
    updateSelection(.create(draft), source: .programmatic)
  }

  @MainActor
  static func freshCreateDraft(
    kind: SessionCreateKind,
    sessionID: String,
    userDefaults: UserDefaults = .standard
  ) -> SessionCreateDraft {
    var draft = SessionCreateDraft(kind: kind, sessionID: sessionID)
    guard kind == .agent else {
      return draft
    }

    draft.useCodex = false
    draft.runtime =
      HarnessMonitorAgentLaunchDefaults.preferredSelection(
        userDefaults: userDefaults
      ).storageKey
    applySavedAgentLaunchPreset(to: &draft, userDefaults: userDefaults)
    return draft
  }

  public func select(_ selection: SessionSelection) {
    updateSelection(selection, source: .programmatic)
  }

  public func selectFromSidebar(_ selection: SessionSelection?) {
    guard let selection else {
      return
    }
    updateSelection(selection, source: .sidebar)
  }

  /// Test seam kept for older selection-source checks. Product sidebar rows use
  /// native `List` selection and do not install tap gestures to classify input.
  public func markPointerSelectionIntent(for selection: SessionSelection) {
    _ = selection
  }

  public func updateCreateDraft(_ draft: SessionCreateDraft) {
    sectionState.createDrafts[draft.kind] = draft
    guard selection.createDraft?.kind == draft.kind else { return }
    selection = .create(draft)
  }

  func didPickCreateLaunchSelectionManually(for kind: SessionCreateKind) -> Bool {
    manualLaunchSelectionKinds.contains(kind)
  }

  func setDidPickCreateLaunchSelectionManually(_ value: Bool, for kind: SessionCreateKind) {
    if value {
      manualLaunchSelectionKinds.insert(kind)
    } else {
      manualLaunchSelectionKinds.remove(kind)
    }
  }

  @discardableResult
  func persistCreateLaunchSelection(
    _ selection: AgentLaunchSelection,
    for draft: SessionCreateDraft
  ) -> SessionCreateDraft {
    HarnessMonitorAgentLaunchDefaults.persist(selection)
    setDidPickCreateLaunchSelectionManually(true, for: draft.kind)
    var next = draft
    next.runtime = selection.storageKey
    updateCreateDraft(next)
    return next
  }

  public func resetCreateDraft(_ kind: SessionCreateKind) {
    setDidPickCreateLaunchSelectionManually(false, for: kind)
    let freshDraft = Self.freshCreateDraft(kind: kind, sessionID: sessionID)
    sectionState.createDrafts[kind] = freshDraft
    if selection.createDraft?.kind == kind {
      selection = .create(freshDraft)
    }
  }

  public func cancelCreateDraft(_ kind: SessionCreateKind) {
    setDidPickCreateLaunchSelectionManually(false, for: kind)
    sectionState.createDrafts[kind] = nil
    updateSelection(
      .route(kind.route),
      source: .programmatic,
      rememberCurrentSelection: false,
      recordHistory: false
    )
  }

  public func navigateBack() {
    guard let previous = navigationHistory.popBack(current: selection) else { return }
    updateSelection(
      previous,
      source: .programmatic,
      rememberCurrentSelection: false,
      recordHistory: false
    )
  }

  public func navigateForward() {
    guard let next = navigationHistory.popForward(current: selection) else { return }
    updateSelection(
      next,
      source: .programmatic,
      rememberCurrentSelection: false,
      recordHistory: false
    )
  }

  public func selectedDecision(in decisions: [Decision]) -> Decision? {
    guard let decisionID = selection.decisionID else {
      return nil
    }
    return decisions.first { $0.id == decisionID }
  }

  public func selectedDecisionVisibility(
    allDecisionIDs: Set<String>,
    visibleDecisionIDs: Set<String>
  ) -> SessionSelectedDecisionVisibility {
    guard let decisionID = selection.decisionID else {
      return .none
    }
    if visibleDecisionIDs.contains(decisionID) {
      return .visible
    }
    if allDecisionIDs.contains(decisionID) {
      return .hidden
    }
    return .missing
  }

  private func updateSelection(
    _ nextSelection: SessionSelection,
    source: SessionSelectionSource,
    rememberCurrentSelection: Bool = true,
    recordHistory: Bool = true
  ) {
    if selection != nextSelection {
      if rememberCurrentSelection {
        sectionState.remember(selection)
      }
      if recordHistory {
        navigationHistory.record(selection)
      }
      selection = nextSelection
    }
    selectionSource = source
    if case .agent = nextSelection, source == .keyboard {
      agentComposerFocusRequestID += 1
    }
  }

  public func beginAgentCreateCatalogLoading() -> Bool {
    guard !agentCreateCatalog.isLoading, !agentCreateCatalog.hasLoaded else {
      return false
    }
    agentCreateCatalog.isLoading = true
    return true
  }

  func finishAgentCreateCatalogLoading(
    descriptors: [AcpAgentDescriptor],
    runtimeModelCatalogs: [RuntimeModelCatalog],
    capabilityOptions: [AgentCapabilityOption],
    personas: [AgentPersona]
  ) {
    agentCreateCatalog = SessionWindowAgentCreateCatalogState(
      descriptors: descriptors,
      runtimeModelCatalogs: runtimeModelCatalogs,
      capabilityOptions: capabilityOptions,
      personas: personas,
      isLoading: false,
      hasLoaded: true
    )
  }

  public func failAgentCreateCatalogLoading() {
    agentCreateCatalog.isLoading = false
  }

  @MainActor
  private static func applySavedAgentLaunchPreset(
    to draft: inout SessionCreateDraft,
    userDefaults: UserDefaults
  ) {
    guard let snapshot = LaunchPresetDefaults.read(userDefaults: userDefaults) else {
      return
    }

    if !HarnessMonitorAgentLaunchDefaults.hasExplicitPreferredProvider(
      userDefaults: userDefaults
    ),
      let providerStorageKey = snapshot.providerStorageKey,
      AgentLaunchSelection(storageKey: providerStorageKey) != nil
    {
      draft.runtime = providerStorageKey
    }
    if let role = snapshot.role.flatMap(SessionRole.init(rawValue:)) {
      draft.role = role
    }
    if let fallbackRole = snapshot.fallbackRole.flatMap(SessionRole.init(rawValue:)) {
      draft.fallbackRole = fallbackRole
    }
    if let personaID = snapshot.personaID, !personaID.isEmpty {
      draft.personaID = personaID
    }
    applyModelPreferences(snapshot: snapshot, to: &draft)
    applyCodexPreferences(snapshot: snapshot, to: &draft)
  }

  private static func applyModelPreferences(
    snapshot: LaunchPresetSnapshot,
    to draft: inout SessionCreateDraft
  ) {
    if !snapshot.modelByRuntime.isEmpty {
      draft.modelByRuntime = snapshot.modelByRuntime
    }
    if !snapshot.customModelByRuntime.isEmpty {
      draft.customModelByRuntime = snapshot.customModelByRuntime
    }
    if !snapshot.effortByRuntime.isEmpty {
      draft.effortByRuntime = snapshot.effortByRuntime
    }
  }

  private static func applyCodexPreferences(
    snapshot: LaunchPresetSnapshot,
    to draft: inout SessionCreateDraft
  ) {
    if let codexMode = snapshot.codexMode.flatMap(CodexRunMode.init(rawValue:)) {
      draft.codexMode = codexMode
    }

    let trimmedCustomCodexModel = snapshot.customCodexModel?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let trimmedCodexModel = snapshot.codexModel?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if let trimmedCustomCodexModel, !trimmedCustomCodexModel.isEmpty {
      draft.codexModel = trimmedCustomCodexModel
      draft.codexAllowCustomModel = true
    } else if let trimmedCodexModel, !trimmedCodexModel.isEmpty {
      draft.codexModel = trimmedCodexModel
      draft.codexAllowCustomModel = false
    }
    if let codexEffort = snapshot.codexEffort?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ),
      !codexEffort.isEmpty
    {
      draft.codexEffort = codexEffort
    }
  }
}

struct SessionWindowAgentCreateCatalogState: Equatable {
  public var descriptors: [AcpAgentDescriptor] = []
  public var runtimeModelCatalogs: [RuntimeModelCatalog] = []
  public var capabilityOptions: [AgentCapabilityOption] = []
  public var personas: [AgentPersona] = []
  public var isLoading = false
  public var hasLoaded = false
}

@MainActor
@Observable
public final class SessionWindowSectionState {
  public var routeSelection: SessionWindowRoute = .overview
  public var agentID: String?
  public var codexRunID: String?
  public var decisionID: String?
  public var taskID: String?
  public var createDrafts: [SessionCreateKind: SessionCreateDraft] = [:]

  public init() {}

  public func remember(_ selection: SessionSelection) {
    switch selection {
    case .route(let route):
      routeSelection = route
    case .agent(_, let agentID):
      self.agentID = agentID
    case .codexRun(_, let runID):
      codexRunID = runID
    case .decision(_, let decisionID):
      self.decisionID = decisionID
    case .task(_, let taskID):
      self.taskID = taskID
    case .create(let draft):
      createDrafts[draft.kind] = draft
    }
  }

  public func hasDraft(_ kind: SessionCreateKind) -> Bool {
    guard let draft = createDrafts[kind] else { return false }
    return !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

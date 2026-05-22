import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

extension HarnessMonitorApp {
  func presentOpenAnythingPalette() {
    keyWindowObserver.refresh()
    if let windowID = openAnythingTargetWindowID() {
      appOpenAnythingPalette.present(targetWindowID: windowID)
      return
    }
    openWindow.openHarnessDashboardWindow()
    focusDashboardWindowIfPossible()
    appOpenAnythingPalette.present(targetWindowID: HarnessMonitorWindowID.dashboard)
  }

  private func openAnythingTargetWindowID() -> String? {
    guard let identifier = keyWindowObserver.snapshot.keyWindowIdentifier else {
      return nil
    }
    if identifier == HarnessMonitorWindowID.dashboard
      || identifier == HarnessMonitorWindowID.settings
      || identifier == HarnessMonitorWindowID.policyCanvasLab
      || identifier.hasPrefix("session-")
    {
      return identifier
    }
    return nil
  }

  private func focusDashboardWindowIfPossible() {
    if #available(macOS 14.0, *) {
      NSApplication.shared.activate()
    } else {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    DashboardWindowAppKitRegistry.shared.window?.makeKeyAndOrderFront(nil)
  }
}

struct HarnessMonitorOpenAnythingHostModifier: ViewModifier {
  let windowID: String
  let model: OpenAnythingPaletteModel
  let dependencyRegistry: OpenAnythingDashboardDependencyRegistry
  let store: HarnessMonitorStore
  let keyWindowObserver: KeyWindowObserver
  let windowNavigationHistory: GlobalWindowNavigationHistory
  let showsPolicyCanvasLab: Bool
  let globalHotKeyController: GlobalHotKeyController
  let globalHotKeyEnabled: Bool
  let globalHotKeyDescriptorStorage: String
  let presentPalette: @MainActor @Sendable () -> Void
  let refreshStore: () -> Void
  @Binding var settingsSelectedSection: SettingsSection
  @Binding var settingsNavigationRequest: SettingsNavigationRequest?
  @Environment(\.openWindow)
  private var openWindow

  func body(content: Content) -> some View {
    content
      .overlay {
        if model.isPresented(in: windowID, isKeyWindow: keyWindowObserver.isKey(windowID: windowID))
        {
          OpenAnythingPaletteView(model: model, execute: execute)
            .zIndex(1_000)
        }
      }
      .background {
        Color.clear
          .frame(width: 0, height: 0)
          .accessibilityHidden(true)
          .task(id: corpusSignature) {
            await model.replaceCorpus(makeRecords())
          }
          .task(id: hotKeySignature) {
            globalHotKeyController.configure(
              enabled: globalHotKeyEnabled,
              descriptor: OpenAnythingHotKeyDescriptor.decode(globalHotKeyDescriptorStorage),
              onInvoke: presentPalette
            )
          }
      }
  }

  private var hotKeySignature: String {
    "\(globalHotKeyEnabled)-\(globalHotKeyDescriptorStorage)"
  }

  private var corpusSignature: Int {
    var hasher = Hasher()
    hasher.combine(showsPolicyCanvasLab)
    hashSettings(into: &hasher)
    hashSessions(into: &hasher)
    hashTaskBoard(into: &hasher)
    hashDecisions(into: &hasher)
    hashDependencies(into: &hasher)
    hashLoadedSession(into: &hasher)
    return hasher.finalize()
  }

  private func makeRecords() -> [OpenAnythingRecord] {
    OpenAnythingCorpusBuilder.records(
      input: OpenAnythingCorpusInput(
        settingsSections: SettingsSection.allCases.map {
          OpenAnythingSettingsSectionProjection(
            rawValue: $0.rawValue,
            title: $0.title,
            systemImage: $0.systemImage
          )
        },
        sessions: store.sessions,
        taskBoardItems: store.globalTaskBoardItems,
        decisions: store.supervisorOpenDecisionPresentationItems,
        dependencies: dependencyRegistry.loadedItems,
        loadedSession: loadedSessionSnapshot,
        showsPolicyCanvasLab: showsPolicyCanvasLab
      )
    )
  }

  private var loadedSessionSnapshot: OpenAnythingLoadedSessionSnapshot? {
    guard let sessionID = store.selectedSessionID else { return nil }
    return OpenAnythingLoadedSessionSnapshot(
      sessionID: sessionID,
      agents: store.selectedSessionAgents,
      tasks: store.selectedSessionTasks,
      timeline: store.timeline
    )
  }

  private func execute(_ hit: OpenAnythingHit) {
    for step in OpenAnythingRouteExecutor.steps(
      for: hit,
      showsPolicyCanvasLab: showsPolicyCanvasLab
    ) {
      executeRoutingStep(step)
    }
  }

  private func executeRoutingStep(_ step: OpenAnythingRoutingStep) {
    guard !executePresentationStep(step) else { return }
    switch step {
    case .openWindow(let target):
      openWindowTarget(target)
    case .openDashboard(let route):
      openDashboard(route)
    case .openSettings(let rawValue):
      openSettings(rawValue: rawValue)
    case .openSessionWindow(let sessionID):
      openWindow.openHarnessSessionWindow(sessionID: sessionID)
    case .requestSessionRoute(let target):
      requestSessionRoute(target)
    case .selectSupervisorDecision(let id):
      store.supervisorSelectedDecisionID = id
    case .selectDashboardDependency(let pullRequestID):
      dependencyRegistry.requestSelection(pullRequestID: pullRequestID)
    case .presentNewSessionSheet, .presentNewTaskSheet, .attachExternalSession, .refresh:
      break
    }
  }

  private func executePresentationStep(_ step: OpenAnythingRoutingStep) -> Bool {
    switch step {
    case .presentNewSessionSheet:
      store.presentedSheet = .newSession
    case .presentNewTaskSheet:
      store.requestCreateTaskSheet()
    case .attachExternalSession:
      store.requestAttachExternalSession()
    case .refresh:
      refreshStore()
    default:
      return false
    }
    return true
  }

  private func openWindowTarget(_ target: OpenAnythingWindowTarget) {
    switch target {
    case .dashboard:
      openWindow.openHarnessDashboardWindow()
    case .settings:
      openWindow(id: HarnessMonitorWindowID.settings)
    case .policyCanvasLab:
      if showsPolicyCanvasLab {
        openWindow(id: HarnessMonitorWindowID.policyCanvasLab)
      }
    }
  }

  private func openDashboard(_ route: OpenAnythingDashboardRoute) {
    let dashboardRoute = DashboardWindowRoute(rawValue: route.rawValue) ?? .taskBoard
    windowNavigationHistory.requestDashboardRoute(dashboardRoute)
    openWindow.openHarnessDashboardWindow()
  }

  private func openSettings(rawValue: String) {
    guard let section = SettingsSection(rawValue: rawValue) else {
      openWindow(id: HarnessMonitorWindowID.settings)
      return
    }
    settingsSelectedSection = section
    settingsNavigationRequest = SettingsNavigationRequest(target: .section(section))
    openWindow(id: HarnessMonitorWindowID.settings)
  }

  private func requestSessionRoute(_ target: OpenAnythingSessionRouteTarget) {
    switch target {
    case .agent(let sessionID, let agentID):
      store.requestSessionRoute(.agent(sessionID: sessionID, agentID: agentID))
    case .task(let sessionID, let taskID):
      store.requestSessionRoute(.task(sessionID: sessionID, taskID: taskID))
    case .decision(let sessionID, let decisionID, let resetDecisionFilters):
      store.requestSessionRoute(
        .decision(sessionID: sessionID, decisionID: decisionID),
        resetDecisionFilters: resetDecisionFilters
      )
    }
  }

  private func hashSettings(into hasher: inout Hasher) {
    for section in SettingsSection.allCases {
      hasher.combine(section.rawValue)
      hasher.combine(section.title)
    }
  }

  private func hashSessions(into hasher: inout Hasher) {
    for session in store.sessions {
      hasher.combine(session.sessionId)
      hasher.combine(session.title)
      hasher.combine(session.updatedAt)
      hasher.combine(session.status.rawValue)
    }
  }

  private func hashTaskBoard(into hasher: inout Hasher) {
    for item in store.globalTaskBoardItems {
      hasher.combine(item.id)
      hasher.combine(item.title)
      hasher.combine(item.updatedAt)
      hasher.combine(item.sessionId)
      hasher.combine(item.workItemId)
    }
  }

  private func hashDecisions(into hasher: inout Hasher) {
    for decision in store.supervisorOpenDecisionPresentationItems {
      hasher.combine(decision.id)
      hasher.combine(decision.summary)
      hasher.combine(decision.sessionID)
      hasher.combine(decision.statusRaw)
    }
  }

  private func hashDependencies(into hasher: inout Hasher) {
    for item in dependencyRegistry.loadedItems {
      hasher.combine(item.pullRequestID)
      hasher.combine(item.title)
      hasher.combine(item.updatedAt)
      hasher.combine(item.checkStatus.rawValue)
    }
  }

  private func hashLoadedSession(into hasher: inout Hasher) {
    hasher.combine(store.selectedSessionID)
    for agent in store.selectedSessionAgents {
      hasher.combine(agent.agentId)
      hasher.combine(agent.name)
      hasher.combine(agent.runtime)
    }
    for task in store.selectedSessionTasks {
      hasher.combine(task.taskId)
      hasher.combine(task.title)
      hasher.combine(task.status.rawValue)
    }
    for entry in store.timeline.prefix(200) {
      hasher.combine(entry.entryId)
      hasher.combine(entry.summary)
      hasher.combine(entry.kind)
    }
  }
}

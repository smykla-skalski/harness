import Foundation

extension HarnessMonitorStore {
  public struct CheckoutGroup: Identifiable, Equatable, Sendable {
    public let checkoutId: String
    public let title: String
    public let isWorktree: Bool
    public let sessionIDs: [String]

    public var id: String { checkoutId }
    public var sessionCount: Int { sessionIDs.count }
  }

  public struct SessionGroup: Identifiable, Equatable, Sendable {
    public let project: ProjectSummary
    public let checkoutGroups: [CheckoutGroup]

    public var sessionIDs: [String] {
      checkoutGroups.flatMap(\.sessionIDs)
    }

    public var id: String { project.id }
  }

  public enum StatusMessageTone: Equatable, Sendable {
    case secondary
    case info
    case success
    case caution
  }

  public struct SessionSummaryPresentation: Equatable, Sendable {
    public struct SidebarStatPresentation: Equatable, Sendable {
      public let symbolName: String
      public let valueText: String
      public let helpText: String

      public init(
        symbolName: String,
        valueText: String,
        helpText: String
      ) {
        self.symbolName = symbolName
        self.valueText = valueText
        self.helpText = helpText
      }
    }

    public let statusText: String
    public let statusTone: StatusMessageTone
    public let isEstimated: Bool
    public let agentStat: SidebarStatPresentation
    public let taskStat: SidebarStatPresentation
    public let accessibilityStatusText: String

    public init(
      statusText: String,
      statusTone: StatusMessageTone,
      isEstimated: Bool,
      agentStat: SidebarStatPresentation,
      taskStat: SidebarStatPresentation,
      accessibilityStatusText: String
    ) {
      self.statusText = statusText
      self.statusTone = statusTone
      self.isEstimated = isEstimated
      self.agentStat = agentStat
      self.taskStat = taskStat
      self.accessibilityStatusText = accessibilityStatusText
    }
  }

  public struct AgentActivityPresentation: Equatable, Sendable {
    public let label: String
    public let accessibilityValue: String

    public init(label: String, accessibilityValue: String) {
      self.label = label
      self.accessibilityValue = accessibilityValue
    }
  }

  public struct AgentLifecyclePresentation: Equatable, Sendable {
    public let label: String
    public let accessibilityValue: String
    public let visualStatus: AgentStatus

    public init(
      label: String,
      accessibilityValue: String,
      visualStatus: AgentStatus
    ) {
      self.label = label
      self.accessibilityValue = accessibilityValue
      self.visualStatus = visualStatus
    }
  }

  public enum AgentPresentationAvailability: Equatable, Sendable {
    case live
    case persisted
    case unavailable
  }

  public struct AgentRuntimePresentationContext: Equatable, Sendable {
    public let availability: AgentPresentationAvailability
    public let acpSnapshots: [AcpAgentSnapshot]
    public let acpInspectSample: AcpInspectSample?

    public init(
      availability: AgentPresentationAvailability,
      acpSnapshots: [AcpAgentSnapshot] = [],
      acpInspectSample: AcpInspectSample? = nil
    ) {
      self.availability = availability
      self.acpSnapshots = acpSnapshots
      self.acpInspectSample = acpInspectSample
    }
  }

  public struct AgentRuntimeSummary: Equatable, Sendable {
    public let registeredCount: Int
    public let activeCount: Int
    public let notRunningCount: Int
    public let disconnectedCount: Int
    public let idleCount: Int
    public let awaitingReviewCount: Int
    public let removedCount: Int

    public init(
      registeredCount: Int,
      activeCount: Int,
      notRunningCount: Int,
      disconnectedCount: Int,
      idleCount: Int,
      awaitingReviewCount: Int,
      removedCount: Int
    ) {
      self.registeredCount = registeredCount
      self.activeCount = activeCount
      self.notRunningCount = notRunningCount
      self.disconnectedCount = disconnectedCount
      self.idleCount = idleCount
      self.awaitingReviewCount = awaitingReviewCount
      self.removedCount = removedCount
    }
  }

  public enum SidebarEmptyState: Equatable, Sendable {
    case noSessions
    case noMatches
    case sessionsAvailable
  }

  public struct InspectorTaskSelectionState: Equatable, Sendable {
    public let task: WorkItem
    public let notesSessionID: String?
    public let isPersistenceAvailable: Bool

    public init(
      task: WorkItem,
      notesSessionID: String?,
      isPersistenceAvailable: Bool
    ) {
      self.task = task
      self.notesSessionID = notesSessionID
      self.isPersistenceAvailable = isPersistenceAvailable
    }
  }

  public struct SessionProjectionState: Equatable, Sendable {
    public var groupedSessions: [SessionGroup] = []
    public var filteredSessionCount = 0
    public var totalSessionCount = 0
    public var emptyState: SidebarEmptyState = .noSessions

    public init(
      groupedSessions: [SessionGroup] = [],
      filteredSessionCount: Int = 0,
      totalSessionCount: Int = 0,
      emptyState: SidebarEmptyState = .noSessions
    ) {
      self.groupedSessions = groupedSessions
      self.filteredSessionCount = filteredSessionCount
      self.totalSessionCount = totalSessionCount
      self.emptyState = emptyState
    }
  }

  public struct SessionSearchPresentationState: Equatable, Sendable {
    public var isSearchActive = false
    public var emptyState: SidebarEmptyState = .noSessions

    public init(
      isSearchActive: Bool = false,
      emptyState: SidebarEmptyState = .noSessions
    ) {
      self.isSearchActive = isSearchActive
      self.emptyState = emptyState
    }
  }

  public struct SessionSearchResultsListState: Equatable, Sendable {
    public var visibleSessionIDs: [String] = []

    public init(
      visibleSessionIDs: [String] = []
    ) {
      self.visibleSessionIDs = visibleSessionIDs
    }
  }

  public struct SessionSearchResultsState: Equatable, Sendable {
    public var presentation = SessionSearchPresentationState()
    public var filteredSessionCount = 0
    public var totalSessionCount = 0
    public var list = SessionSearchResultsListState()

    public init(
      presentation: SessionSearchPresentationState = SessionSearchPresentationState(),
      filteredSessionCount: Int = 0,
      totalSessionCount: Int = 0,
      list: SessionSearchResultsListState = SessionSearchResultsListState()
    ) {
      self.presentation = presentation
      self.filteredSessionCount = filteredSessionCount
      self.totalSessionCount = totalSessionCount
      self.list = list
    }
  }
}

extension HarnessMonitorStore {
  private func sessionSummaryStatusTone(
    status: SessionStatus,
    isEstimated: Bool,
    isLeaderless: Bool
  ) -> StatusMessageTone {
    if isEstimated {
      return .secondary
    }
    if status == .awaitingLeader {
      return .info
    }
    if isLeaderless {
      return .caution
    }
    switch status {
    case .awaitingLeader:
      return .info
    case .active:
      return .success
    case .leaderlessDegraded, .paused:
      return .caution
    case .ended:
      return .secondary
    }
  }

  private func sessionSummaryAgentStat(
    for summary: SessionSummary,
    usesLiveAgentPhrasing: Bool
  ) -> SessionSummaryPresentation.SidebarStatPresentation {
    let agentCount =
      usesLiveAgentPhrasing
      ? summary.metrics.activeAgentCount
      : summary.metrics.agentCount
    return SessionSummaryPresentation.SidebarStatPresentation(
      symbolName: usesLiveAgentPhrasing ? "person.2.fill" : "person.2",
      valueText: "\(agentCount)",
      helpText: usesLiveAgentPhrasing ? "\(agentCount) active" : "\(agentCount) known"
    )
  }

  public func sessionSummaryPresentation(
    for summary: SessionSummary
  ) -> SessionSummaryPresentation {
    let isEstimated = sessionCatalogIsEstimated
    let isMalformedActiveLeaderless =
      summary.status == .active
      && summary.leaderId == nil
    let isLeaderless =
      summary.status == .leaderlessDegraded
      || isMalformedActiveLeaderless
    let usesKnownAgentPhrasing =
      summary.status == .awaitingLeader
      || isLeaderless

    let statusText =
      if summary.status == .awaitingLeader {
        "Awaiting Leader"
      } else if isLeaderless {
        "Leaderless"
      } else {
        summary.status.title
      }
    let statusTone = sessionSummaryStatusTone(
      status: summary.status,
      isEstimated: isEstimated,
      isLeaderless: isLeaderless
    )

    let usesLiveAgentPhrasing =
      !isEstimated
      && !usesKnownAgentPhrasing
      && summary.status == .active
    let agentStat = sessionSummaryAgentStat(
      for: summary,
      usesLiveAgentPhrasing: usesLiveAgentPhrasing
    )
    let movingTaskCount = summary.metrics.inProgressTaskCount
    let taskStat = SessionSummaryPresentation.SidebarStatPresentation(
      symbolName: "arrow.triangle.2.circlepath",
      valueText: "\(movingTaskCount)",
      helpText: "\(movingTaskCount) moving"
    )

    return SessionSummaryPresentation(
      statusText: statusText,
      statusTone: statusTone,
      isEstimated: isEstimated,
      agentStat: agentStat,
      taskStat: taskStat,
      accessibilityStatusText: isEstimated ? "\(statusText), estimated" : statusText
    )
  }

  public func usesLiveRuntimePresentation(for sessionID: String) -> Bool {
    selectedSessionID == sessionID && sessionDataAvailability == .live
  }

  private func agentPresentationAvailability(
    for sessionID: String
  ) -> AgentPresentationAvailability? {
    guard selectedSessionID == sessionID else {
      return nil
    }
    switch sessionDataAvailability {
    case .live:
      return .live
    case .persisted:
      return .persisted
    case .unavailable:
      return .unavailable
    }
  }

  private func resolvedPresentationAvailability(
    for sessionID: String,
    runtimePresentation: AgentRuntimePresentationContext?
  ) -> AgentPresentationAvailability? {
    runtimePresentation?.availability ?? agentPresentationAvailability(for: sessionID)
  }

  private func acpWatchdogLifecyclePresentation(
    runtimeState: AcpAgentRuntimeState,
    fallbackStatus: AgentStatus
  ) -> AgentLifecyclePresentation? {
    let normalized = runtimeState.watchdogState?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let status: AgentStatus
    let accessibilityValue: String
    switch normalized {
    case "active":
      status = .active
      accessibilityValue = "Active, ACP watchdog active"
    case "paused":
      status = .idle
      accessibilityValue = "Idle, ACP watchdog paused"
    default:
      return nil
    }
    guard status != fallbackStatus else {
      return nil
    }
    let label = status.title
    return AgentLifecyclePresentation(
      label: label,
      accessibilityValue: accessibilityValue,
      visualStatus: status
    )
  }

  // Selected-session ACP registrations can outlive the daemon/runtime that
  // originally marked them active. When the selected session is cached or
  // offline, prefer a truthful disconnected label over replaying persisted
  // `.active` state.
  private func unavailableSelectedAcpLifecyclePresentation(
    for availability: AgentPresentationAvailability
  ) -> AgentLifecyclePresentation {
    if availability == .live {
      return AgentLifecyclePresentation(
        label: "Not Running",
        accessibilityValue: "No live ACP runtime observed",
        visualStatus: .disconnected
      )
    }

    let accessibilityValue: String
    switch availability {
    case .persisted:
      accessibilityValue = "Showing cached data; live ACP runtime unavailable"
    case .unavailable:
      accessibilityValue = "Daemon offline; live ACP runtime unavailable"
    case .live:
      accessibilityValue = "No live ACP runtime observed"
    }

    return AgentLifecyclePresentation(
      label: "Disconnected",
      accessibilityValue: accessibilityValue,
      visualStatus: .disconnected
    )
  }

  public func agentLifecyclePresentation(
    for agent: AgentRegistration,
    sessionID: String,
    sessionRegistrations: [AgentRegistration],
    tuiStatus: AgentTuiStatus?,
    runtimePresentation: AgentRuntimePresentationContext? = nil
  ) -> AgentLifecyclePresentation {
    let resolvedPresentationAvailability = resolvedPresentationAvailability(
      for: sessionID,
      runtimePresentation: runtimePresentation
    )

    if agent.managedAgent?.kind == .acp,
      agent.status == .active,
      let resolvedPresentationAvailability,
      resolvedPresentationAvailability != .live
    {
      return unavailableSelectedAcpLifecyclePresentation(for: resolvedPresentationAvailability)
    }

    let liveAcpRuntimeState: AcpAgentRuntimeState? =
      if agent.managedAgent?.kind == .acp,
        resolvedPresentationAvailability == .live
      {
        if let runtimePresentation {
          acpRuntimeState(
            for: SessionAgentID(rawValue: agent.agentId),
            sessionID: sessionID,
            sessionRegistrations: sessionRegistrations,
            snapshots: runtimePresentation.acpSnapshots,
            inspectSample: runtimePresentation.acpInspectSample
          )
        } else {
          acpRuntimeState(
            for: agent.agentId,
            sessionID: sessionID,
            sessionRegistrations: sessionRegistrations
          )
        }
      } else {
        nil
      }

    guard resolvedPresentationAvailability == .live else {
      let label = agent.status.title
      return AgentLifecyclePresentation(
        label: label,
        accessibilityValue: label,
        visualStatus: agent.status
      )
    }

    if agent.managedAgent?.kind == .acp,
      agent.status == .active,
      liveAcpRuntimeState == nil
    {
      return unavailableSelectedAcpLifecyclePresentation(for: .live)
    }

    if let liveAcpRuntimeState,
      let runtimeLifecycle = acpWatchdogLifecyclePresentation(
        runtimeState: liveAcpRuntimeState,
        fallbackStatus: agent.status
      )
    {
      return runtimeLifecycle
    }

    if let tuiStatus, agent.managedAgent?.kind == .tui, tuiStatus.isActive == false {
      return AgentLifecyclePresentation(
        label: tuiStatus.title,
        accessibilityValue: tuiStatus.title,
        visualStatus: .disconnected
      )
    }

    let label = agent.status.title
    return AgentLifecyclePresentation(
      label: label,
      accessibilityValue: label,
      visualStatus: agent.status
    )
  }

  public func agentActivityPresentation(
    for agent: AgentRegistration,
    sessionID: String,
    sessionRegistrations: [AgentRegistration],
    queuedTasks: [WorkItem],
    tuiStatus: AgentTuiStatus?,
    runtimePresentation: AgentRuntimePresentationContext? = nil
  ) -> AgentActivityPresentation {
    let lifecycle = agentLifecyclePresentation(
      for: agent,
      sessionID: sessionID,
      sessionRegistrations: sessionRegistrations,
      tuiStatus: tuiStatus,
      runtimePresentation: runtimePresentation
    )

    if lifecycle.label == "Not Running" {
      return AgentActivityPresentation(
        label: "No live ACP runtime",
        accessibilityValue: "No live ACP runtime observed"
      )
    }

    switch lifecycle.visualStatus {
    case .disconnected:
      return AgentActivityPresentation(
        label: lifecycle.label,
        accessibilityValue: lifecycle.accessibilityValue
      )
    case .removed:
      return AgentActivityPresentation(
        label: lifecycle.label,
        accessibilityValue: lifecycle.accessibilityValue
      )
    case .awaitingReview:
      return AgentActivityPresentation(
        label: lifecycle.label,
        accessibilityValue: lifecycle.accessibilityValue
      )
    case .idle:
      return AgentActivityPresentation(
        label: lifecycle.label,
        accessibilityValue: lifecycle.accessibilityValue
      )
    case .active:
      guard
        resolvedPresentationAvailability(
          for: sessionID,
          runtimePresentation: runtimePresentation
        ) == .live
      else {
        return AgentActivityPresentation(
          label: "Snapshot",
          accessibilityValue: "Estimated activity"
        )
      }
      if !queuedTasks.isEmpty {
        let suffix = queuedTasks.count == 1 ? "task" : "tasks"
        return AgentActivityPresentation(
          label: "\(queuedTasks.count) queued \(suffix)",
          accessibilityValue: "\(queuedTasks.count) queued"
        )
      }
      let label = agent.currentTaskId == nil ? "Ready" : "Working"
      return AgentActivityPresentation(label: label, accessibilityValue: label)
    }
  }

  public func agentRuntimeSummary(
    sessionID: String,
    sessionRegistrations: [AgentRegistration],
    tuiStatusByAgent: [String: AgentTuiStatus],
    runtimePresentation: AgentRuntimePresentationContext? = nil
  ) -> AgentRuntimeSummary {
    var activeCount = 0
    var notRunningCount = 0
    var disconnectedCount = 0
    var idleCount = 0
    var awaitingReviewCount = 0
    var removedCount = 0

    for agent in sessionRegistrations {
      let lifecycle = agentLifecyclePresentation(
        for: agent,
        sessionID: sessionID,
        sessionRegistrations: sessionRegistrations,
        tuiStatus: tuiStatusByAgent[agent.agentId],
        runtimePresentation: runtimePresentation
      )

      switch lifecycle.label {
      case "Not Running", AgentTuiStatus.stopped.title, AgentTuiStatus.exited.title,
        AgentTuiStatus.failed.title:
        notRunningCount += 1
      default:
        switch lifecycle.visualStatus {
        case .active:
          activeCount += 1
        case .disconnected:
          disconnectedCount += 1
        case .idle:
          idleCount += 1
        case .awaitingReview:
          awaitingReviewCount += 1
        case .removed:
          removedCount += 1
        }
      }
    }

    return AgentRuntimeSummary(
      registeredCount: sessionRegistrations.count,
      activeCount: activeCount,
      notRunningCount: notRunningCount,
      disconnectedCount: disconnectedCount,
      idleCount: idleCount,
      awaitingReviewCount: awaitingReviewCount,
      removedCount: removedCount
    )
  }
}

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
    public var groupedSessions: [SessionGroup] = []

    public init(
      presentation: SessionSearchPresentationState = SessionSearchPresentationState(),
      filteredSessionCount: Int = 0,
      totalSessionCount: Int = 0,
      list: SessionSearchResultsListState = SessionSearchResultsListState(),
      groupedSessions: [SessionGroup] = []
    ) {
      self.presentation = presentation
      self.filteredSessionCount = filteredSessionCount
      self.totalSessionCount = totalSessionCount
      self.list = list
      self.groupedSessions = groupedSessions
    }
  }
}

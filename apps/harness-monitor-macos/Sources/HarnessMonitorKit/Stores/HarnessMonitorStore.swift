// swiftlint:disable file_length
import Foundation
import Observation
import SwiftData

struct PendingSessionDetailCacheWrite: Sendable {
  let snapshot: SessionCacheService.CachedSessionSnapshot
  let markViewed: Bool
  let preservesTimeline: Bool
}

@MainActor
@Observable
// swiftlint:disable:next type_body_length attributes
public final class HarnessMonitorStore {
  public let connection: ConnectionSlice
  public let sessionIndex: SessionIndexSlice
  public let selection: SelectionSlice
  public let userData: UserDataSlice
  public let contentUI: ContentUISlice
  public let sidebarUI: SidebarUISlice
  public let toast: ToastSlice
  @ObservationIgnored public let supervisorToolbarSlice: SupervisorToolbarSlice
  public let bookmarkStore: BookmarkStore?
  @ObservationIgnored var supervisorStack: SupervisorStack?
  @ObservationIgnored var supervisorBindings = SupervisorBindings()
  @ObservationIgnored var supervisorStartTask: Task<Void, Never>?
  @ObservationIgnored var supervisorStopTask: Task<Void, Never>?
  @ObservationIgnored let supervisorTickTrigger = SupervisorTickTrigger()
  @ObservationIgnored let acpTimelineWorker = AcpTimelineWorker()
  @ObservationIgnored let acpRuntimeWorker = AcpRuntimeWorker()
  @ObservationIgnored let sessionSnapshotWorker = SessionSnapshotWorker()
  @ObservationIgnored let launchWindowRestoreWorker = LaunchWindowRestoreWorker()
  @ObservationIgnored let sessionCacheWriteWorker = SessionCacheWriteWorker()
  @ObservationIgnored let timelineWindowWorker = TimelineWindowWorker()
  @ObservationIgnored let sessionWindowPresentationWorker = SessionWindowPresentationWorker()
  @ObservationIgnored let taskBoardSettingsWorker = TaskBoardSettingsWorker()
  @ObservationIgnored var sessionIndexSnapshotApplyTask: Task<Void, Never>?
  @ObservationIgnored var sessionIndexSnapshotApplyGeneration: UInt64 = 0
  @ObservationIgnored var acpTimelineMergeTask: Task<Void, Never>?
  @ObservationIgnored var acpTranscriptMergeTask: Task<Void, Never>?
  @ObservationIgnored var acpTranscriptLiveMergeTask: Task<Void, Never>?
  @ObservationIgnored var acpTranscriptHistoryTask: Task<Void, Never>?
  @ObservationIgnored var acpTimelineReattributeTask: Task<Void, Never>?
  @ObservationIgnored var acpTranscriptReattributeTask: Task<Void, Never>?
  @ObservationIgnored var acpTranscriptPartitionTask: Task<Void, Never>?
  @ObservationIgnored var acpTimelineMergeGeneration: UInt64 = 0
  @ObservationIgnored var acpTranscriptMergeGeneration: UInt64 = 0
  @ObservationIgnored var acpTranscriptLiveMergeGeneration: UInt64 = 0
  @ObservationIgnored var acpTranscriptHistoryGeneration: UInt64 = 0
  @ObservationIgnored var acpTimelineReattributeGeneration: UInt64 = 0
  @ObservationIgnored var acpTranscriptReattributeGeneration: UInt64 = 0
  @ObservationIgnored var acpTranscriptPartitionGeneration: UInt64 = 0
  @ObservationIgnored var acpRuntimeStateGeneration: UInt64 = 0
  @ObservationIgnored var cachedNullActionHandler: NullDecisionActionHandler?
  @ObservationIgnored var openSessionWindowsByID: [ObjectIdentifier: String] = [:]
  @ObservationIgnored var pendingSessionWindowTerminationSnapshot: Set<String>?
  @ObservationIgnored var pendingSessionWindowQuitSnapshot: SessionWindowQuitSnapshot?
  @ObservationIgnored var isSuppressingNotificationHistoryToast = false
  @ObservationIgnored var suppressedNotificationHistoryToastIDs: Set<UUID> = []

  public var openFolderRequest = 0
  public var attachSessionRequest = 0
  public var lastExternalSessionAttachOutcome: ExternalSessionAttachOutcome?
  public var supervisorSelectedDecisionID: String?
  public var supervisorOpenDecisions: [Decision] = []
  public var supervisorOpenDecisionsByID: [String: Decision] = [:]
  public var supervisorOpenDecisionsBySession: [String: [Decision]] = [:]
  public var supervisorOpenDecisionPresentationItems: [DecisionPresentationSnapshot] = []
  // swiftlint:disable:next identifier_name
  public var supervisorOpenDecisionPresentationItemsBySession:
    [String: [DecisionPresentationSnapshot]] = [:]
  public var supervisorOpenDecisionSearchProjections: [DecisionSearchProjection] = []
  // swiftlint:disable:next identifier_name
  public var supervisorOpenDecisionSearchProjectionsBySession:
    [String: [DecisionSearchProjection]] = [:]
  public var supervisorOpenDecisionIDsBySession: [String: [String]] = [:]
  public var supervisorDecisionRefreshTick: Int = 0
  public internal(set) var supervisorLiveTickRefreshTick: Int = 0
  public internal(set) var supervisorRuntimeState: SupervisorRuntimeState = .stopped
  public var globalTaskBoardItems: [TaskBoardItem] = [] {
    didSet {
      guard oldValue != globalTaskBoardItems else { return }
      scheduleUISync([.contentDashboard])
    }
  }
  public var globalTaskBoardOrchestratorStatus: TaskBoardOrchestratorStatus? {
    didSet {
      guard oldValue != globalTaskBoardOrchestratorStatus else { return }
      scheduleUISync([.contentDashboard])
    }
  }
  public var globalTaskBoardSyncSummary: TaskBoardSyncSummary? {
    didSet {
      guard oldValue != globalTaskBoardSyncSummary else { return }
      scheduleUISync([.contentDashboard])
    }
  }
  public var globalTaskBoardDispatchSummary: TaskBoardDispatchSummary? {
    didSet {
      guard oldValue != globalTaskBoardDispatchSummary else { return }
      scheduleUISync([.contentDashboard])
    }
  }
  public var globalTaskBoardEvaluationSummary: TaskBoardEvaluationSummary? {
    didSet {
      guard oldValue != globalTaskBoardEvaluationSummary else { return }
      scheduleUISync([.contentDashboard])
    }
  }
  public var globalTaskBoardItemAuditSummary: TaskBoardAuditSummary? {
    didSet {
      guard oldValue != globalTaskBoardItemAuditSummary else { return }
      scheduleUISync([.contentDashboard])
    }
  }
  public var globalTaskBoardProjects: [TaskBoardProjectSummary]? {
    didSet {
      guard oldValue != globalTaskBoardProjects else { return }
      scheduleUISync([.contentDashboard])
    }
  }
  public var globalTaskBoardMachines: [TaskBoardMachineSummary]? {
    didSet {
      guard oldValue != globalTaskBoardMachines else { return }
      scheduleUISync([.contentDashboard])
    }
  }
  public var globalTaskBoardPolicyPipeline: TaskBoardPolicyPipelineDocument? {
    didSet {
      guard oldValue != globalTaskBoardPolicyPipeline else { return }
      scheduleUISync([.contentDashboard])
    }
  }
  public var globalTaskBoardPolicySimulation: TaskBoardPolicyPipelineSimulationResult? {
    didSet {
      guard oldValue != globalTaskBoardPolicySimulation else { return }
      scheduleUISync([.contentDashboard])
    }
  }
  public var globalTaskBoardPolicyAudit: TaskBoardPolicyPipelineAuditSummary? {
    didSet {
      guard oldValue != globalTaskBoardPolicyAudit else { return }
      scheduleUISync([.contentDashboard])
    }
  }
  public var notificationHistoryEntries: [NotificationHistoryEntry] = [] {
    didSet {
      guard oldValue != notificationHistoryEntries else { return }
      scheduleUISync([.contentDashboard])
    }
  }
  public var supervisorObserverFocusTick: Int = 0
  public var supervisorPrimaryActionFocusDecisionID: String?
  public var supervisorPrimaryActionFocusRequestTick: Int = 0
  var supervisorLiveTick: DecisionLiveTickSnapshot = .placeholder

  public var persistenceError: String? {
    didSet {
      guard oldValue != persistenceError else { return }
      scheduleUISync([.contentChrome])
    }
  }
  public var presentedSheet: PresentedSheet? {
    didSet {
      guard oldValue != presentedSheet else { return }
      scheduleUISync([.contentShell])
    }
  }
  public var pendingConfirmation: PendingConfirmation? {
    didSet {
      guard oldValue != pendingConfirmation else { return }
      scheduleUISync([.contentShell])
    }
  }
  public var pendingSessionRoute: SessionRouteSelection?
  public internal(set) var pendingSessionRouteRequestID = 0
  var pendingSessionRouteDecisionFilterReset = false
  var pendingSessionRouteCreateEntryPoint: SessionRouteCreateEntryPoint?
  var pendingSessionRouteCreateSessionID: String?
  public var hostBridgeCapabilityIssues: [String: HostBridgeCapabilityIssue] = [:]
  public var acpBridgeHTTPIncident: AcpBridgeHTTPIncident? {
    didSet {
      guard oldValue != acpBridgeHTTPIncident else { return }
      scheduleUISync([.contentChrome])
    }
  }
  public var mcpStatus = HarnessMonitorMCPStatusSnapshot(
    runtimeState: .disabled,
    recoveryStatus: nil
  ) {
    didSet {
      guard oldValue != mcpStatus else { return }
      scheduleUISync([.contentChrome])
    }
  }
  @ObservationIgnored var mcpFeedbackState = MCPStatusFeedbackState()
  @ObservationIgnored var forcedHostBridgeCapabilities: Set<String> = []
  public var selectedCodexRuns: [CodexRunSnapshot] = [] {
    didSet {
      guard oldValue != selectedCodexRuns else { return }
    }
  }
  public var selectedCodexRun: CodexRunSnapshot? {
    didSet {
      guard oldValue != selectedCodexRun else { return }
    }
  }
  public var selectedAgentTuis: [AgentTuiSnapshot] = [] {
    didSet {
      guard oldValue != selectedAgentTuis else { return }
    }
  }
  public var selectedAgentTui: AgentTuiSnapshot? {
    didSet {
      guard oldValue != selectedAgentTui else { return }
    }
  }
  public var selectedAcpAgents: [AcpAgentSnapshot] = [] {
    didSet {
      guard oldValue != selectedAcpAgents else { return }
      rebuildAcpDecisionAttentionCache()
    }
  }
  @ObservationIgnored var selectedAcpTranscriptHistoryEntries: [TimelineEntry] = [] {
    didSet {
      guard oldValue != selectedAcpTranscriptHistoryEntries else { return }
      rebuildSelectedAcpTranscriptEntries()
    }
  }
  @ObservationIgnored var selectedAcpTranscriptLiveEntries: [TimelineEntry] = [] {
    didSet {
      guard oldValue != selectedAcpTranscriptLiveEntries else { return }
      rebuildSelectedAcpTranscriptEntries()
    }
  }
  @ObservationIgnored var selectedAcpTranscriptEntries: [TimelineEntry] = [] {
    didSet {
      guard oldValue != selectedAcpTranscriptEntries else { return }
      rebuildAcpTranscriptPartition()
    }
  }
  @ObservationIgnored var selectedAcpTranscriptSource: HarnessMonitorSessionWindowTranscriptSource?
  var acpTranscriptByAgentID: [String: [TimelineEntry]] = [:]
  /// Derived ACP attention for the currently selected session only.
  ///
  /// Freshness contract:
  /// - This cache is rebuilt only when `selectedAcpAgents` changes, so it cannot outlive the
  ///   store's selected-session ACP snapshot.
  /// - No background cache or independent invalidation path exists; replacing `selectedAcpAgents`
  ///   is the only way the attention model changes.
  ///
  /// Ordering contract:
  /// - `oldestBatchID` is selected by daemon-authored `(createdAt, batchId)` ordering to make the
  ///   oldest pending ACP batch deterministic when batches arrive in unstable array order.
  public internal(set) var acpDecisionAttentionSnapshot = AcpDecisionAttentionSnapshot(
    byAgentID: [:]
  )
  public internal(set) var acpPermissionAttentionEvents: [AcpPermissionAttentionEvent] = []
  var selectedAcpInspectState: AcpInspectSample? {
    didSet {
      guard oldValue != selectedAcpInspectState else { return }
      reconcileAcpRuntimeClock()
    }
  }
  @ObservationIgnored public var acpRuntimeClockTick = Date.now
  var selectedAcpInspectSyncEntries: [AcpRuntimeIdentity: AcpInspectSyncEntry] = [:]
  public var liveToolCallAnnouncementRowIDs: Set<String> = []
  public var toolCallTimelineOverflowNotice: ToolCallTimelineOverflowNotice?
  @ObservationIgnored var acpAgentDescriptorsByID: [String: AcpAgentDescriptor] = [:]
  var standaloneAcpPermissionBatches: [AcpPermissionBatch] = []
  public var presentingAcpPermissionBatch: AcpPermissionBatch?
  public var resolvingAcpPermissionBatchID: String?
  public var acpPermissionResolutionStateByDecisionID: [String: BatchResolutionState] = [:]
  @ObservationIgnored var acpPermissionPayloadsByDecisionID:
    [String: AcpPermissionDecisionPayload] =
      [:]
  var acpPermissionLastSignalAtBySessionID: [String: Date] = [:]
  @ObservationIgnored var acpPermissionPendingTimeoutDecisionIDs: Set<String> = []
  @ObservationIgnored var acpPermissionPendingShutdownDecisionIDs: Set<String> = []
  @ObservationIgnored var acpPermissionTerminalOutcomesByID: [String: DecisionOutcome] = [:]
  @ObservationIgnored var acpPermissionAuditEncoder = JSONEncoder()
  @ObservationIgnored var acpPermissionOutcomeDecoder = JSONDecoder()
  @ObservationIgnored var acpPermissionDecisionSyncTask: Task<Void, Never>?
  @ObservationIgnored var acpPermissionDecisionSyncGeneration: UInt64 = 0
  @ObservationIgnored var acpPermissionDeadlineResolutionTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var acpDeadlineResolutionTokens: [String: UInt64] = [:]
  @ObservationIgnored var acpPermissionShutdownResolutionTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var acpShutdownResolutionTokens: [String: UInt64] = [:]
  public var sleepPreventionEnabled = false {
    didSet {
      guard oldValue != sleepPreventionEnabled else { return }
      sleepAssertion.update(hasActiveSessions: sleepPreventionEnabled)
      scheduleUISync([.contentToolbar])
    }
  }
  var manualRefreshSuccessToken = 0 {
    didSet {
      guard oldValue != manualRefreshSuccessToken else { return }
      scheduleUISync([.contentToolbar])
    }
  }
  public var navigationBackStack: [String?] = [] {
    didSet {
      guard oldValue != navigationBackStack else { return }
      scheduleUISync([.contentToolbar])
    }
  }
  public var navigationForwardStack: [String?] = [] {
    didSet {
      guard oldValue != navigationForwardStack else { return }
      scheduleUISync([.contentToolbar])
    }
  }
  var connectionProbeInterval: Duration = .seconds(10)
  var bootstrapWarmUpTimeout: Duration = .seconds(15)
  var initialConnectRefreshRetryGracePeriod: Duration = .seconds(2)
  var initialConnectRefreshRetryInterval: Duration = .milliseconds(200)
  var initialTaskBoardConfirmationGracePeriod: Duration = .seconds(5)
  var initialTaskBoardConfirmationRetryInterval: Duration = .milliseconds(250)
  var acpInspectGracePeriod: Duration = .seconds(2)
  var acpInspectRecoveryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
  var managedLaunchAgentRefreshMinimumInterval: Duration = .seconds(10)
  var selectedSessionRefreshFallbackDelay: Duration = .seconds(5)
  var sessionPushFallbackDelay: Duration = .seconds(5)
  var sessionPushFallbackMinimumInterval: Duration = .seconds(5)
  var appInactivitySuspendDelay: Duration = .seconds(5)
  var externalManifestDiscoveryInterval: Duration = .seconds(1)
  var timelineMinimumLoadingDuration: Duration = .milliseconds(500)
  @ObservationIgnored var timelineLoadingGateClock: any TimelineLoadingGateClock =
    LiveContinuousClockSource()

  let daemonController: any DaemonControlling
  public let daemonOwnership: DaemonOwnership
  let fileViewer: any FileViewerActivating
  @ObservationIgnored public let voiceCapture: any VoiceCaptureProviding
  @ObservationIgnored var resourceMetricsSampler: any HarnessMonitorResourceSampling =
    HarnessMonitorResourceMetrics.shared
  public let modelContext: ModelContext?
  let cacheService: SessionCacheService?
  let userDataService: UserDataPersistenceService?
  public let supervisorPolicyConfigRepository: SupervisorPolicyConfigRepository?
  public let supervisorAuditRepository: SupervisorAuditRepository?
  var client: (any HarnessMonitorClientProtocol)?
  var globalStreamTask: Task<Void, Never>?
  var sessionStreamTask: Task<Void, Never>?
  var connectionProbeTask: Task<Void, Never>?
  var sessionPushFallbackTask: Task<Void, Never>?
  @ObservationIgnored var appInactivitySuspendTask: Task<Void, Never>?
  @ObservationIgnored var initialTaskBoardConfirmationTask: Task<Void, Never>?
  @ObservationIgnored var selectedSessionRefreshFallbackTask: Task<Void, Never>?
  var sessionSnapshotHydrationTask: Task<Void, Never>?
  @ObservationIgnored var sessionLoadTask: Task<Void, Never>?
  @ObservationIgnored var sessionLoadTaskToken: UInt64 = 0
  @ObservationIgnored var timelineLoadingGateTask: Task<Void, Never>?
  @ObservationIgnored var sessionSecondaryHydrationTask: Task<Void, Never>?
  @ObservationIgnored var sessionSecondaryHydrationTaskToken: UInt64 = 0
  @ObservationIgnored var acpInspectRecoveryTask: Task<Void, Never>?
  @ObservationIgnored var acpRuntimeClockTask: Task<Void, Never>?
  var selectionTask: Task<Void, Never>?
  var codexRunsBySessionID: [String: [CodexRunSnapshot]] = [:]
  var openRouterRunsBySessionID: [String: [OpenRouterRunSnapshot]] = [:]
  @ObservationIgnored var openRouterRunMetadata: [String: OpenRouterRunMetadata] = [:]
  @ObservationIgnored var locallyRemovedSessionIDs: Set<String> = []
  @ObservationIgnored var pendingListSelectionTask: Task<Void, Never>?
  @ObservationIgnored var pendingListSelectionTaskToken: UInt64 = 0
  @ObservationIgnored var selectedTimelinePageLoadTask: Task<Void, Never>?
  @ObservationIgnored var selectedTimelinePageLoadKey: SelectedTimelinePageLoadKey?
  @ObservationIgnored var selectedTimelinePageLoadSequence: UInt64 = 0
  @ObservationIgnored var selectedTimelinePreferredWindowLimit: Int?
  @ObservationIgnored var selectedTimelineWindowLoadTask: Task<Void, Never>?
  @ObservationIgnored var selectedTimelineWindowLoadKey: SelectedTimelineWindowLoadKey?
  @ObservationIgnored var selectedTimelineWindowLoadSequence: UInt64 = 0
  var pendingCacheWriteTask: Task<Void, Never>?
  @ObservationIgnored var pendingCacheWriteTaskToken: UInt64 = 0
  @ObservationIgnored var pendingTaskBoardSnapshotCacheWriteTask: Task<Void, Never>?
  @ObservationIgnored var pendingTaskBoardSnapshotCacheWriteTaskToken: UInt64 = 0
  @ObservationIgnored var pendingSessionDetailCacheWriteTask: Task<Void, Never>?
  @ObservationIgnored var pendingSessionDetailCacheWriteTaskToken: UInt64 = 0
  @ObservationIgnored var pendingSessionDetailCacheWrites:
    [String: PendingSessionDetailCacheWrite] = [:]
  @ObservationIgnored var suppressSelectedAcpTranscriptCacheWrite = false
  @ObservationIgnored var agentTuiActionRefreshTask: Task<Void, Never>?
  var manifestWatcher: ManifestWatcher?
  @ObservationIgnored let manifestWatcherStartupWorker = ManifestWatcherStartupWorker()
  @ObservationIgnored var manifestWatcherStartTask: Task<Void, Never>?
  @ObservationIgnored var externalManifestDiscoveryTask: Task<Void, Never>?
  @ObservationIgnored var manifestURL = HarnessMonitorPaths.manifestURLWithoutLiveDiscovery()
  var transportLatencySamplesMs: [Int] = []
  var requestLatencySamplesMs: [Int] = []
  var trafficSampleTimes: [Date] = []
  var activeSessionLoadRequest: UInt64 = 0
  var sessionLoadSequence: UInt64 = 0
  var sessionPushFallbackSequence: UInt64 = 0
  @ObservationIgnored var selectedSessionRefreshFallbackSequence: UInt64 = 0
  @ObservationIgnored var agentTuiActionRefreshSequence: UInt64 = 0
  @ObservationIgnored var acpInspectRecoverySequence: UInt64 = 0
  @ObservationIgnored var timelineLoadingGateStartedAt: ContinuousClock.Instant?
  var pendingSessionPushFallback: (sessionID: String, token: UInt64)?
  @ObservationIgnored var pendingSelectedSessionRefreshFallback: (sessionID: String, token: UInt64)?
  @ObservationIgnored var lastSessionPushFallbackAt: [String: ContinuousClock.Instant] = [:]
  @ObservationIgnored var lastManagedLaunchAgentRefreshAt: ContinuousClock.Instant?
  @ObservationIgnored var hasRefreshedManagedLaunchAgentOnLaunch = false
  @ObservationIgnored var pendingAgentTuiActionRefresh: (tuiID: String, token: UInt64)?
  var pendingExtensions: SessionExtensionsPayload?
  var isNavigatingHistory = false
  var hasBootstrapped = false
  @ObservationIgnored var bootstrapTask: Task<Void, Never>?
  var isBootstrapping = false
  var isReconnecting = false
  var isAppLifecycleSuspended = false
  var reconnectRequestedDuringReconnect = false
  private let sleepAssertion = SleepAssertion()
  @ObservationIgnored var pendingUISyncAreas: Set<UISyncArea> = []
  @ObservationIgnored var isApplyingUISyncBatch = false
  @ObservationIgnored var debugUISyncCounts: [UISyncArea: Int] = [:]
  @ObservationIgnored var notificationHistoryRuntimeActions: [String: @MainActor () async -> Void] =
    [:]

  public init(
    daemonController: any DaemonControlling,
    fileViewer: any FileViewerActivating = WorkspaceFileViewer(),
    voiceCapture: any VoiceCaptureProviding,
    daemonOwnership: DaemonOwnership = .managed,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil,
    cacheService: SessionCacheService? = nil
  ) {
    self.connection = ConnectionSlice()
    self.sessionIndex = SessionIndexSlice()
    self.selection = SelectionSlice()
    self.userData = UserDataSlice()
    self.contentUI = ContentUISlice()
    self.sidebarUI = SidebarUISlice()
    self.toast = ToastSlice()
    self.supervisorToolbarSlice = SupervisorToolbarSlice()
    self.bookmarkStore = Self.makeBookmarkStore()
    self.daemonController = daemonController
    self.daemonOwnership = daemonOwnership
    self.fileViewer = fileViewer
    self.voiceCapture = voiceCapture
    self.modelContext = modelContainer?.mainContext
    self.userDataService = modelContainer.map {
      UserDataPersistenceService(
        modelContainer: $0,
        maxRecentSearches: Self.maxRecentSearches
      )
    }
    self.supervisorPolicyConfigRepository = modelContainer.map(
      SupervisorPolicyConfigRepository.init)
    self.supervisorAuditRepository = modelContainer.map(SupervisorAuditRepository.init)
    if let cacheService {
      self.cacheService = cacheService
    } else if let modelContainer {
      self.cacheService = SessionCacheService(
        modelContainer: modelContainer,
        databaseURL: HarnessMonitorPaths.cacheStoreURL()
      )
    } else {
      self.cacheService = nil
    }
    self.persistenceError = persistenceError
    if let raw = ProcessInfo.processInfo.environment["HARNESS_BOOTSTRAP_TIMEOUT_SECONDS"],
      let seconds = Double(raw),
      seconds > 0
    {
      self.bootstrapWarmUpTimeout = .seconds(seconds)
    }
    let seeded = Self.parseForcedBridgeIssues(
      from: ProcessInfo.processInfo.environment
    )
    self.hostBridgeCapabilityIssues = seeded
    self.forcedHostBridgeCapabilities = Set(seeded.keys)
    configureToastHistoryEvents()
    bindUISlices()
    syncAllUI()
    scheduleBookmarkedSessionRefresh()
    scheduleNotificationHistoryRefresh()
  }

}

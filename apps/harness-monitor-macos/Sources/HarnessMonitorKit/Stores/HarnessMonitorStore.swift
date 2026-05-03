import Foundation
import Observation
import SwiftData

@MainActor
@Observable
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

  public var openFolderRequest = 0
  public var attachSessionRequest = 0
  public var lastExternalSessionAttachOutcome: ExternalSessionAttachOutcome?
  public var supervisorSelectedDecisionID: String?
  public var supervisorOpenDecisions: [Decision] = []
  public var supervisorDecisionRefreshTick: Int = 0
  public var supervisorObserverFocusTick: Int = 0
  public var supervisorPrimaryActionFocusDecisionID: String?
  public var supervisorPrimaryActionFocusRequestTick: Int = 0

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
  public var pendingWorkspaceSelection: WorkspaceSelection?
  var pendingWorkspaceDecisionFilterReset = false
  var pendingWorkspaceCreateEntryPoint: WorkspaceCreateEntryPoint?
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
      scheduleUISync([.contentToolbar, .contentChrome])
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
    }
  }
  var selectedAcpInspectState: AcpInspectSample? {
    didSet {
      guard oldValue != selectedAcpInspectState else { return }
    }
  }
  public var selectedAcpInspectAgents: [AcpAgentInspectSnapshot] {
    selectedAcpInspectState?.agents ?? []
  }
  public var selectedAcpInspectObservedAt: Date? {
    selectedAcpInspectState?.sampledAt
  }
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
  @ObservationIgnored var acpPermissionDecisionSyncTask: Task<Void, Never>?
  @ObservationIgnored var acpPermissionDecisionSyncGeneration: UInt64 = 0
  public var showConfirmation: Bool {
    get { pendingConfirmation != nil }
    set { if !newValue { cancelConfirmation() } }
  }
  public var sleepPreventionEnabled = false {
    didSet {
      guard oldValue != sleepPreventionEnabled else { return }
      sleepAssertion.update(hasActiveSessions: sleepPreventionEnabled)
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
  var acpInspectGracePeriod: Duration = .seconds(2)
  var acpInspectRecoveryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
  var managedLaunchAgentRefreshMinimumInterval: Duration = .seconds(10)
  var selectedSessionRefreshFallbackDelay: Duration = .seconds(5)
  var sessionPushFallbackDelay: Duration = .seconds(5)
  var sessionPushFallbackMinimumInterval: Duration = .seconds(5)
  var appInactivitySuspendDelay: Duration = .seconds(5)
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
  var client: (any HarnessMonitorClientProtocol)?
  var globalStreamTask: Task<Void, Never>?
  var sessionStreamTask: Task<Void, Never>?
  var connectionProbeTask: Task<Void, Never>?
  var sessionPushFallbackTask: Task<Void, Never>?
  @ObservationIgnored var appInactivitySuspendTask: Task<Void, Never>?
  @ObservationIgnored var selectedSessionRefreshFallbackTask: Task<Void, Never>?
  var sessionSnapshotHydrationTask: Task<Void, Never>?
  @ObservationIgnored var sessionLoadTask: Task<Void, Never>?
  @ObservationIgnored var sessionLoadTaskToken: UInt64 = 0
  @ObservationIgnored var timelineLoadingGateTask: Task<Void, Never>?
  @ObservationIgnored var sessionSecondaryHydrationTask: Task<Void, Never>?
  @ObservationIgnored var sessionSecondaryHydrationTaskToken: UInt64 = 0
  @ObservationIgnored var acpInspectRecoveryTask: Task<Void, Never>?
  var selectionTask: Task<Void, Never>?
  var codexRunsBySessionID: [String: [CodexRunSnapshot]] = [:]
  @ObservationIgnored var locallyRemovedSessionIDs: Set<String> = []
  @ObservationIgnored var pendingListSelectionTask: Task<Void, Never>?
  @ObservationIgnored var pendingListSelectionTaskToken: UInt64 = 0
  @ObservationIgnored var selectedTimelinePageLoadTask: Task<Void, Never>?
  @ObservationIgnored var selectedTimelinePageLoadKey: SelectedTimelinePageLoadKey?
  @ObservationIgnored var selectedTimelinePageLoadSequence: UInt64 = 0
  @ObservationIgnored var selectedTimelineWindowLoadTask: Task<Void, Never>?
  @ObservationIgnored var selectedTimelineWindowLoadKey: SelectedTimelineWindowLoadKey?
  @ObservationIgnored var selectedTimelineWindowLoadSequence: UInt64 = 0
  var pendingCacheWriteTask: Task<Void, Never>?
  @ObservationIgnored var pendingCacheWriteTaskToken: UInt64 = 0
  @ObservationIgnored var agentTuiActionRefreshTask: Task<Void, Never>?
  var manifestWatcher: ManifestWatcher?
  @ObservationIgnored var manifestURL = HarnessMonitorPaths.manifestURL()
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
  @ObservationIgnored var pendingAgentTuiActionRefresh: (tuiID: String, token: UInt64)?
  var pendingExtensions: SessionExtensionsPayload?
  var isNavigatingHistory = false
  var hasBootstrapped = false
  var isBootstrapping = false
  var isReconnecting = false
  var isAppLifecycleSuspended = false
  var reconnectRequestedDuringReconnect = false
  private let sleepAssertion = SleepAssertion()
  @ObservationIgnored var pendingUISyncAreas: Set<UISyncArea> = []
  @ObservationIgnored var isApplyingUISyncBatch = false
  @ObservationIgnored var debugUISyncCounts: [UISyncArea: Int] = [:]

  var maintainsLiveDaemonObservation: Bool {
    !(daemonController is PreviewDaemonController)
  }

  public convenience init(
    daemonController: any DaemonControlling,
    fileViewer: any FileViewerActivating = WorkspaceFileViewer(),
    daemonOwnership: DaemonOwnership = .managed,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil,
    cacheService: SessionCacheService? = nil
  ) {
    self.init(
      daemonController: daemonController,
      fileViewer: fileViewer,
      voiceCapture: NativeVoiceCaptureService(),
      daemonOwnership: daemonOwnership,
      modelContainer: modelContainer,
      persistenceError: persistenceError,
      cacheService: cacheService
    )
  }

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
    bindUISlices()
    refreshBookmarkedSessionIds()
    syncAllUI()
  }

}

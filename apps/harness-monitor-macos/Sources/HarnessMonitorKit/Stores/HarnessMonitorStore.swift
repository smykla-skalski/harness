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
  public let inspectorUI: InspectorUISlice
  public let toast: ToastSlice

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
  public var hostBridgeCapabilityIssues: [String: HostBridgeCapabilityIssue] = [:]
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
  var managedLaunchAgentRefreshMinimumInterval: Duration = .seconds(10)
  var selectedSessionRefreshFallbackDelay: Duration = .seconds(5)
  var sessionPushFallbackDelay: Duration = .seconds(5)
  var sessionPushFallbackMinimumInterval: Duration = .seconds(5)
  var timelineMinimumLoadingDuration: Duration = .milliseconds(500)
  @ObservationIgnored var timelineLoadingGateClock: any TimelineLoadingGateClock =
    LiveContinuousClockSource()

  let daemonController: any DaemonControlling
  public let daemonOwnership: DaemonOwnership
  let fileViewer: any FileViewerActivating
  @ObservationIgnored public let voiceCapture: any VoiceCaptureProviding
  public let modelContext: ModelContext?
  let cacheService: SessionCacheService?
  var client: (any HarnessMonitorClientProtocol)?
  var globalStreamTask: Task<Void, Never>?
  var sessionStreamTask: Task<Void, Never>?
  var connectionProbeTask: Task<Void, Never>?
  var sessionPushFallbackTask: Task<Void, Never>?
  @ObservationIgnored var selectedSessionRefreshFallbackTask: Task<Void, Never>?
  var sessionSnapshotHydrationTask: Task<Void, Never>?
  @ObservationIgnored var sessionLoadTask: Task<Void, Never>?
  @ObservationIgnored var sessionLoadTaskToken: UInt64 = 0
  @ObservationIgnored var timelineLoadingGateTask: Task<Void, Never>?
  @ObservationIgnored var sessionSecondaryHydrationTask: Task<Void, Never>?
  @ObservationIgnored var sessionSecondaryHydrationTaskToken: UInt64 = 0
  var selectionTask: Task<Void, Never>?
  @ObservationIgnored var pendingListSelectionTask: Task<Void, Never>?
  @ObservationIgnored var pendingListSelectionTaskToken: UInt64 = 0
  @ObservationIgnored var selectedTimelinePageLoadTask: Task<Void, Never>?
  @ObservationIgnored var selectedTimelinePageLoadKey: SelectedTimelinePageLoadKey?
  @ObservationIgnored var selectedTimelinePageLoadSequence: UInt64 = 0
  var pendingCacheWriteTask: Task<Void, Never>?
  @ObservationIgnored var pendingCacheWriteTaskToken: UInt64 = 0
  @ObservationIgnored var agentTuiActionRefreshTask: Task<Void, Never>?
  var manifestWatcher: ManifestWatcher?
  @ObservationIgnored var manifestURL = HarnessMonitorPaths.manifestURL()
  var latencySamplesMs: [Int] = []
  var trafficSampleTimes: [Date] = []
  var activeSessionLoadRequest: UInt64 = 0
  var sessionLoadSequence: UInt64 = 0
  var sessionPushFallbackSequence: UInt64 = 0
  @ObservationIgnored var selectedSessionRefreshFallbackSequence: UInt64 = 0
  @ObservationIgnored var agentTuiActionRefreshSequence: UInt64 = 0
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
  var reconnectRequestedDuringReconnect = false
  private let sleepAssertion = SleepAssertion()
  @ObservationIgnored var pendingUISyncAreas: Set<UISyncArea> = []
  @ObservationIgnored var isApplyingUISyncBatch = false
  @ObservationIgnored var debugUISyncCounts: [UISyncArea: Int] = [:]
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
    self.inspectorUI = InspectorUISlice()
    self.toast = ToastSlice()
    self.daemonController = daemonController
    self.daemonOwnership = daemonOwnership
    self.fileViewer = fileViewer
    self.voiceCapture = voiceCapture
    self.modelContext = modelContainer?.mainContext
    if let cacheService {
      self.cacheService = cacheService
    } else if let modelContainer {
      self.cacheService = SessionCacheService(modelContainer: modelContainer)
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

  public func bootstrapIfNeeded() async {
    guard !hasBootstrapped else {
      return
    }
    hasBootstrapped = true
    refreshBookmarkedSessionIds()
    await refreshPersistedSessionMetadata()
    await bootstrap()
  }

  public func bootstrap() async {
    connectionState = .connecting

    isBootstrapping = true
    defer {
      isBootstrapping = false
      replayQueuedReconnectAfterBootstrapIfNeeded()
    }

    switch daemonOwnership {
    case .external:
      await bootstrapExternalDaemon()
    case .managed:
      await bootstrapManagedDaemon()
    }
  }

  private func bootstrapManagedDaemon() async {
    let registrationState: DaemonLaunchAgentRegistrationState
    do {
      registrationState = try await ensureManagedLaunchAgentReady()
    } catch {
      await applyLaunchAgentOfflineState(reason: error.localizedDescription)
      return
    }

    switch registrationState {
    case .notRegistered, .notFound:
      await applyLaunchAgentOfflineState(
        reason: "Launch agent not installed. Install to start the daemon."
      )
      return
    case .requiresApproval:
      await applyLaunchAgentOfflineState(
        reason: "Launch agent needs approval in System Settings > General > Login Items."
      )
      return
    case .enabled:
      break
    }

    do {
      let client = try await awaitManagedDaemonWarmUpWithRecovery()
      await connect(using: client)
    } catch {
      let recovered = await recoverManagedBootstrapFailure(from: error)
      guard !recovered else {
        return
      }
    }
  }

  private func bootstrapExternalDaemon() async {
    // Conflict detection: warn if the SMAppService launch agent is still
    // registered. The Rust singleton lock prevents data corruption, but the
    // two daemons race for the manifest and the user sees confusing startup
    // behavior. Surface a clear, non-blocking hint in the connection log.
    let registrationState = await daemonController.launchAgentRegistrationState()
    if registrationState == .enabled {
      appendConnectionEvent(
        kind: .error,
        detail: "SMAppService launch agent is still registered. Remove it in "
          + "System Settings > General > Login Items to avoid conflicts with "
          + "`harness daemon dev`."
      )
    }
    do {
      let client = try await daemonController.awaitManifestWarmUp(
        timeout: bootstrapWarmUpTimeout
      )
      await connect(using: client)
    } catch {
      let message =
        (error as? DaemonControlError)?.errorDescription
        ?? "External daemon not running. Start it with `harness daemon dev` in a terminal."
      markConnectionOffline(message)
      presentFailureFeedback(message)
      await restorePersistedSessionState()
      // External mode: keep the manifest watcher running while offline so
      // the first valid manifest write auto-reconnects without a user action.
      startManifestWatcher()
    }
  }

}

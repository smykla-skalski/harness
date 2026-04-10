import Foundation
import Observation
import SwiftData

@MainActor
@Observable
public final class HarnessMonitorStore {
  public enum ConnectionState: Equatable {
    case idle
    case connecting
    case online
    case offline(String)
  }

  public enum SessionFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case ended

    public var id: String { rawValue }

    public var title: String {
      rawValue.capitalized
    }

    func includes(_ status: SessionStatus) -> Bool {
      switch self {
      case .active:
        status != .ended
      case .all:
        true
      case .ended:
        status == .ended
      }
    }
  }

  public enum InspectorSelection: Equatable {
    case none
    case task(String)
    case agent(String)
    case signal(String)
    case observer
  }

  public enum PendingConfirmation: Equatable {
    case endSession(sessionID: String, actorID: String)
    case removeAgent(sessionID: String, agentID: String, actorID: String)
  }

  public enum PresentedSheet: Identifiable, Equatable {
    case codexFlow
    case sendSignal(agentID: String)

    public var id: String {
      switch self {
      case .codexFlow: "codexFlow"
      case .sendSignal(let agentID): "sendSignal:\(agentID)"
      }
    }
  }

  public let connection: ConnectionSlice
  public let sessionIndex: SessionIndexSlice
  public let selection: SelectionSlice
  public let userData: UserDataSlice
  public let contentUI: ContentUISlice
  public let sidebarUI: SidebarUISlice
  public let inspectorUI: InspectorUISlice

  public var lastAction = "" {
    didSet {
      guard oldValue != lastAction else { return }
      scheduleUISync([.content, .inspector])
    }
  }
  public var lastError: String? {
    didSet {
      guard oldValue != lastError else { return }
      scheduleUISync([.inspector])
    }
  }
  public var persistenceError: String? {
    didSet {
      guard oldValue != persistenceError else { return }
      scheduleUISync([.content, .sidebar, .inspector])
    }
  }
  public var presentedSheet: PresentedSheet? {
    didSet {
      guard oldValue != presentedSheet else { return }
      scheduleUISync([.content])
    }
  }
  public var pendingConfirmation: PendingConfirmation? {
    didSet {
      guard oldValue != pendingConfirmation else { return }
      scheduleUISync([.content])
    }
  }
  public var codexUnavailable = false
  public var selectedCodexRuns: [CodexRunSnapshot] = [] {
    didSet {
      guard oldValue != selectedCodexRuns else { return }
      scheduleUISync([.content])
    }
  }
  public var selectedCodexRun: CodexRunSnapshot? {
    didSet {
      guard oldValue != selectedCodexRun else { return }
      scheduleUISync([.content])
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
      scheduleUISync([.content])
    }
  }
  public var navigationBackStack: [String?] = [] {
    didSet {
      guard oldValue != navigationBackStack else { return }
      scheduleUISync([.content])
    }
  }
  public var navigationForwardStack: [String?] = [] {
    didSet {
      guard oldValue != navigationForwardStack else { return }
      scheduleUISync([.content])
    }
  }
  var connectionProbeInterval: Duration = .seconds(10)
  var lastActionDismissDelay: Duration = .seconds(4)
  var bootstrapWarmUpTimeout: Duration = .seconds(15)

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
  var sessionSnapshotHydrationTask: Task<Void, Never>?
  var selectionTask: Task<Void, Never>?
  var pendingCacheWriteTask: Task<Void, Never>?
  var manifestWatcher: ManifestWatcher?
  var latencySamplesMs: [Int] = []
  var trafficSampleTimes: [Date] = []
  var activeSessionLoadRequest: UInt64 = 0
  var sessionLoadSequence: UInt64 = 0
  var sessionPushFallbackSequence: UInt64 = 0
  var pendingSessionPushFallback: (sessionID: String, token: UInt64)?
  var pendingExtensions: SessionExtensionsPayload?
  var isNavigatingHistory = false
  private var hasBootstrapped = false
  private var isReconnecting = false
  private var reconnectRequestedDuringReconnect = false
  private var lastActionDismissTask: Task<Void, Never>?
  private let sleepAssertion = SleepAssertion()
  @ObservationIgnored var pendingUISyncAreas: Set<UISyncArea> = []
  @ObservationIgnored var isApplyingUISyncBatch = false

  public convenience init(
    daemonController: any DaemonControlling,
    fileViewer: any FileViewerActivating = WorkspaceFileViewer(),
    daemonOwnership: DaemonOwnership = .managed,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil
  ) {
    self.init(
      daemonController: daemonController,
      fileViewer: fileViewer,
      voiceCapture: NativeVoiceCaptureService(),
      daemonOwnership: daemonOwnership,
      modelContainer: modelContainer,
      persistenceError: persistenceError
    )
  }

  public init(
    daemonController: any DaemonControlling,
    fileViewer: any FileViewerActivating = WorkspaceFileViewer(),
    voiceCapture: any VoiceCaptureProviding,
    daemonOwnership: DaemonOwnership = .managed,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil
  ) {
    self.connection = ConnectionSlice()
    self.sessionIndex = SessionIndexSlice()
    self.selection = SelectionSlice()
    self.userData = UserDataSlice()
    self.contentUI = ContentUISlice()
    self.sidebarUI = SidebarUISlice()
    self.inspectorUI = InspectorUISlice()
    self.daemonController = daemonController
    self.daemonOwnership = daemonOwnership
    self.fileViewer = fileViewer
    self.voiceCapture = voiceCapture
    self.modelContext = modelContainer?.mainContext
    if let modelContainer {
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
    lastError = nil

    switch daemonOwnership {
    case .external:
      await bootstrapExternalDaemon()
    case .managed:
      await bootstrapManagedDaemon()
    }
  }

  private func bootstrapManagedDaemon() async {
    let registrationState = await daemonController.launchAgentRegistrationState()
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
      let client = try await daemonController.awaitManifestWarmUp(
        timeout: bootstrapWarmUpTimeout
      )
      await connect(using: client)
    } catch {
      markConnectionOffline(error.localizedDescription)
      await restorePersistedSessionState()
    }
  }

  private func bootstrapExternalDaemon() async {
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
      await restorePersistedSessionState()
    }
  }

  public func focusSidebarSearch() {
    sidebarUI.searchFocusRequest += 1
  }

  private func applyLaunchAgentOfflineState(reason: String) async {
    let launchAgent = await daemonController.launchAgentSnapshot()
    daemonStatus = DaemonStatusReport(
      manifest: nil,
      launchAgent: launchAgent,
      projectCount: 0,
      worktreeCount: 0,
      sessionCount: 0,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "",
        manifestPath: "",
        authTokenPath: "",
        authTokenPresent: false,
        eventsPath: "",
        databasePath: "",
        databaseSizeBytes: 0,
        lastEvent: nil
      )
    )
    markConnectionOffline(reason)
    await restorePersistedSessionState()
  }

  public func startDaemon() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    var registrationState = await daemonController.launchAgentRegistrationState()
    if registrationState == .notRegistered || registrationState == .notFound {
      do {
        registrationState = try await daemonController.registerLaunchAgent()
      } catch {
        await applyLaunchAgentOfflineState(reason: error.localizedDescription)
        return
      }
    }

    switch registrationState {
    case .requiresApproval:
      await applyLaunchAgentOfflineState(
        reason: "Launch agent needs approval in System Settings > General > Login Items."
      )
      return
    case .notRegistered, .notFound:
      await applyLaunchAgentOfflineState(
        reason: "Launch agent registration did not complete."
      )
      return
    case .enabled:
      break
    }

    do {
      let client = try await daemonController.awaitManifestWarmUp(
        timeout: bootstrapWarmUpTimeout
      )
      await connect(using: client)
    } catch {
      markConnectionOffline(error.localizedDescription)
      await restorePersistedSessionState()
    }
  }

  public func stopDaemon() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await daemonController.stopDaemon()
      stopAllStreams()
      stopManifestWatcher()
      client = nil
      markConnectionOffline("Daemon stopped")
      await refreshDaemonStatus()
      await restorePersistedSessionState()
      showLastAction("Stop daemon")
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func installLaunchAgent() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await daemonController.installLaunchAgent()
      await refreshDaemonStatus()
      showLastAction("Install launch agent")
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func removeLaunchAgent() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await daemonController.removeLaunchAgent()
      await refreshDaemonStatus()
      showLastAction("Remove launch agent")
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func refreshDaemonStatus() async {
    do {
      daemonStatus = try await daemonController.daemonStatus()
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func reconnect() async {
    if isReconnecting {
      reconnectRequestedDuringReconnect = true
      return
    }
    isReconnecting = true

    repeat {
      reconnectRequestedDuringReconnect = false
      stopAllStreams()
      let oldClient = client
      client = nil
      if let oldClient {
        await oldClient.shutdown()
      }
      codexUnavailable = false
      hasBootstrapped = true
      await bootstrap()

      guard reconnectRequestedDuringReconnect, connectionState != .online else {
        break
      }
      // A manifest change was detected during bootstrap - the attempt above
      // likely used a stale endpoint. Give the daemon a moment to accept
      // connections on the new port before retrying.
      try? await Task.sleep(for: .milliseconds(500))
    } while true

    isReconnecting = false
  }

  public func prepareForTermination() async {
    clearLastAction()
    stopAllStreams()
    stopManifestWatcher()

    guard let client else {
      return
    }

    self.client = nil
    await client.shutdown()
  }

  public func refreshDiagnostics() async {
    isDiagnosticsRefreshInFlight = true
    defer { isDiagnosticsRefreshInFlight = false }

    guard let client else {
      await refreshDaemonStatus()
      diagnostics = nil
      return
    }

    do {
      let measuredDiagnostics = try await Self.measureOperation {
        try await client.diagnostics()
      }
      diagnostics = measuredDiagnostics.value
      health = measuredDiagnostics.value.health
      daemonStatus = DaemonStatusReport(diagnosticsReport: measuredDiagnostics.value)
      recordRequestSuccess()
    } catch {
      lastError = error.localizedDescription
    }
  }

  public func refresh() async {
    guard let client else {
      await bootstrap()
      return
    }
    await refresh(using: client, preserveSelection: true)
  }

  public func configureUITestBehavior(lastActionDismissDelay: Duration) {
    self.lastActionDismissDelay = lastActionDismissDelay
  }

  public func showLastAction(_ action: String) {
    lastActionDismissTask?.cancel()
    lastAction = action

    guard !action.isEmpty else {
      lastActionDismissTask = nil
      return
    }

    let delay = lastActionDismissDelay
    lastActionDismissTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled, self.lastAction == action else {
        return
      }
      self.lastAction = ""
      self.lastActionDismissTask = nil
    }
  }

  public func clearLastAction() {
    lastActionDismissTask?.cancel()
    lastActionDismissTask = nil
    lastAction = ""
  }
  func stopGlobalStream() {
    globalStreamTask?.cancel()
    globalStreamTask = nil
  }

  func stopSessionStream(resetSubscriptions: Bool = true) {
    sessionStreamTask?.cancel()
    sessionStreamTask = nil
    if resetSubscriptions {
      subscribedSessionIDs.removeAll()
    }
  }

  func stopAllStreams(resetSubscriptions: Bool = true) {
    stopGlobalStream()
    stopSessionStream(resetSubscriptions: resetSubscriptions)
    stopConnectionProbe()
    cancelSessionPushFallback()
    sessionSnapshotHydrationTask?.cancel()
    sessionSnapshotHydrationTask = nil
  }
}

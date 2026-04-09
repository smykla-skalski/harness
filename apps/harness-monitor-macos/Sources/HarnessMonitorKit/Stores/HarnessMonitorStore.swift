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
    case sendSignal(agentID: String)

    public var id: String {
      switch self {
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
    didSet { scheduleUISync([.content, .inspector]) }
  }
  public var lastError: String? {
    didSet { scheduleUISync([.inspector]) }
  }
  public var persistenceError: String? {
    didSet { scheduleUISync([.content, .sidebar, .inspector]) }
  }
  public var presentedSheet: PresentedSheet? {
    didSet { scheduleUISync([.content]) }
  }
  public var pendingConfirmation: PendingConfirmation? {
    didSet { scheduleUISync([.content]) }
  }
  public var showConfirmation: Bool {
    get { pendingConfirmation != nil }
    set { if !newValue { cancelConfirmation() } }
  }
  public var sleepPreventionEnabled = false {
    didSet {
      sleepAssertion.update(hasActiveSessions: sleepPreventionEnabled)
      scheduleUISync([.content])
    }
  }
  public var navigationBackStack: [String?] = [] {
    didSet { scheduleUISync([.content]) }
  }
  public var navigationForwardStack: [String?] = [] {
    didSet { scheduleUISync([.content]) }
  }
  var connectionProbeInterval: Duration = .seconds(10)
  var lastActionDismissDelay: Duration = .seconds(4)

  let daemonController: any DaemonControlling
  let fileViewer: any FileViewerActivating
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

  public init(
    daemonController: any DaemonControlling,
    fileViewer: any FileViewerActivating = WorkspaceFileViewer(),
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
    self.fileViewer = fileViewer
    self.modelContext = modelContainer?.mainContext
    if let modelContainer {
      self.cacheService = SessionCacheService(modelContainer: modelContainer)
    } else {
      self.cacheService = nil
    }
    self.persistenceError = persistenceError
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

    do {
      let client = try await daemonController.bootstrapClient()
      await connect(using: client)
    } catch {
      markConnectionOffline(error.localizedDescription)
      await restorePersistedSessionState()
    }
  }

  public func startDaemon() async {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let client = try await daemonController.startDaemonClient()
      try? await Task.sleep(for: .milliseconds(300))
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

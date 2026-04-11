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

  public enum HostBridgeCapabilityIssue: Equatable {
    case unavailable
    case excluded
  }

  public enum HostBridgeCapabilityState: Equatable {
    case ready
    case unavailable
    case excluded
  }

  public enum HostBridgeCapabilityMutationResult: Equatable {
    case success
    case requiresForce(String)
    case failed
  }

  public enum PresentedSheet: Identifiable, Equatable {
    case codexFlow
    case agentTui
    case sendSignal(agentID: String)

    public var id: String {
      switch self {
      case .codexFlow: "codexFlow"
      case .agentTui: "agentTui"
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
  public let toast: ToastSlice
  public var lastAction: String {
    get {
      toast.activeFeedback.first { $0.severity == .success }?.message ?? ""
    }
    set {
      if newValue.isEmpty {
        toast.dismissAllMatching(severity: .success)
      } else {
        toast.presentSuccess(newValue)
      }
    }
  }
  public var lastError: String? {
    get {
      toast.activeFeedback.first { $0.severity == .failure }?.message
    }
    set {
      if let newValue, !newValue.isEmpty {
        toast.presentFailure(newValue)
      } else {
        toast.dismissAllMatching(severity: .failure)
      }
    }
  }

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
  @ObservationIgnored private var forcedHostBridgeCapabilities: Set<String> = []
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
  private var isBootstrapping = false
  private var isReconnecting = false
  private var reconnectRequestedDuringReconnect = false
  private let sleepAssertion = SleepAssertion()
  @ObservationIgnored var pendingUISyncAreas: Set<UISyncArea> = []
  @ObservationIgnored var isApplyingUISyncBatch = false
  @ObservationIgnored var debugUISyncCounts: [UISyncArea: Int] = [:]
  public var lastActionDismissDelay: Duration {
    get { toast.successDismissDelay }
    set {
      toast.successDismissDelay = newValue
      toast.failureDismissDelay = newValue
    }
  }

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
    self.toast = ToastSlice()
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
    defer { isBootstrapping = false }

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
      let client = try await awaitManagedDaemonWarmUpWithRecovery()
      await connect(using: client)
    } catch {
      markConnectionOffline(error.localizedDescription)
      await restorePersistedSessionState()
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
      await restorePersistedSessionState()
      // External mode: keep the manifest watcher running while offline so
      // the first valid manifest write auto-reconnects without a user action.
      startManifestWatcher()
    }
  }

  public func focusSidebarSearch() {
    sidebarUI.searchFocusRequest += 1
  }

  private func awaitManagedDaemonWarmUpWithRecovery() async throws
    -> any HarnessMonitorClientProtocol
  {
    do {
      return try await daemonController.awaitManifestWarmUp(
        timeout: bootstrapWarmUpTimeout
      )
    } catch {
      guard shouldRefreshManagedLaunchAgent(after: error) else {
        throw error
      }
      appendConnectionEvent(
        kind: .reconnecting,
        detail: "Managed daemon did not become healthy; refreshing the bundled launch agent"
      )
      _ = try await daemonController.removeLaunchAgent()
      let registrationState = try await daemonController.registerLaunchAgent()
      switch registrationState {
      case .enabled:
        break
      case .requiresApproval:
        throw DaemonControlError.commandFailed(
          "Launch agent needs approval in System Settings > General > Login Items."
        )
      case .notRegistered, .notFound:
        throw DaemonControlError.commandFailed("Launch agent registration did not complete.")
      }
      return try await daemonController.awaitManifestWarmUp(
        timeout: bootstrapWarmUpTimeout
      )
    }
  }

  private func shouldRefreshManagedLaunchAgent(after error: any Error) -> Bool {
    guard let daemonError = error as? DaemonControlError else {
      return false
    }
    switch daemonError {
    case .daemonDidNotStart, .daemonOffline, .manifestMissing, .manifestUnreadable:
      return true
    case .harnessBinaryNotFound, .externalDaemonOffline, .externalDaemonManifestStale,
      .commandFailed:
      return false
    }
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
      let client = try await awaitManagedDaemonWarmUpWithRecovery()
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
      presentFailureFeedback(error.localizedDescription)
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
      presentFailureFeedback(error.localizedDescription)
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
      presentFailureFeedback(error.localizedDescription)
    }
  }

  public func refreshDaemonStatus() async {
    do {
      daemonStatus = try await daemonController.daemonStatus()
    } catch {
      presentFailureFeedback(error.localizedDescription)
    }
  }

  public func reconnect() async {
    // If a bootstrap is already running (e.g. the watcher fired mid-warm-up
    // in external mode), record the request so bootstrap can replay it and
    // return; avoids re-entering bootstrap from the MainActor hop.
    if isBootstrapping || isReconnecting {
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
      hostBridgeCapabilityIssues = hostBridgeCapabilityIssues.filter {
        forcedHostBridgeCapabilities.contains($0.key)
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
      presentFailureFeedback(error.localizedDescription)
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
    toast.successDismissDelay = lastActionDismissDelay
    toast.failureDismissDelay = lastActionDismissDelay
  }

  public func showLastAction(_ action: String) {
    lastAction = action
    guard !action.isEmpty else {
      dismissFeedback(severity: .success)
      return
    }
    dismissFeedback(severity: .success)
    toast.presentSuccess(action)
  }

  public func clearLastAction() {
    lastAction = ""
    dismissFeedback(severity: .success)
  }

  @discardableResult
  public func presentSuccessFeedback(_ message: String) -> UUID {
    lastAction = message
    return toast.presentSuccess(message)
  }

  @discardableResult
  public func presentFailureFeedback(_ message: String) -> UUID {
    lastError = message
    return toast.presentFailure(message)
  }

  public func dismissFeedback(id: UUID) {
    toast.dismiss(id: id)
  }

  private func dismissFeedback(severity: ActionFeedback.Severity) {
    let matchingIDs = toast.activeFeedback.compactMap { feedback in
      feedback.severity == severity ? feedback.id : nil
    }
    for id in matchingIDs {
      toast.dismiss(id: id)
    }
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

  public func hostBridgeCapabilityState(for capability: String) -> HostBridgeCapabilityState {
    guard daemonStatus?.manifest?.sandboxed == true else {
      return .ready
    }

    let hostBridge = daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
    if let issue = hostBridgeCapabilityIssues[capability] {
      switch issue {
      case .unavailable:
        return .unavailable
      case .excluded:
        guard hostBridge.running else {
          return .unavailable
        }
        if let capabilityState = hostBridge.capabilities[capability] {
          return capabilityState.healthy ? .ready : .unavailable
        }
        return .excluded
      }
    }

    guard hostBridge.running else {
      return .unavailable
    }
    guard let capabilityState = hostBridge.capabilities[capability] else {
      return .excluded
    }
    return capabilityState.healthy ? .ready : .unavailable
  }

  public static func parseForcedBridgeIssues(
    from environment: [String: String]
  ) -> [String: HostBridgeCapabilityIssue] {
    guard
      let rawValue = environment["HARNESS_MONITOR_FORCE_BRIDGE_ISSUES"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.isEmpty
    else {
      return [:]
    }

    var issues: [String: HostBridgeCapabilityIssue] = [:]
    for capability in rawValue.split(separator: ",") {
      let trimmedCapability = capability.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedCapability.isEmpty else {
        continue
      }
      issues[trimmedCapability] = .excluded
    }
    return issues
  }

  public func hostBridgeStartCommand(for capability: String) -> String {
    let hostBridge = daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
    if hostBridge.running {
      return "harness bridge reconfigure --enable \(capability)"
    }
    return "harness bridge start"
  }

  public func clearHostBridgeIssue(for capability: String) {
    guard hostBridgeCapabilityIssues[capability] != nil else {
      return
    }
    if forcedHostBridgeCapabilities.contains(capability) {
      return
    }
    hostBridgeCapabilityIssues.removeValue(forKey: capability)
  }

  func clearTransientHostBridgeIssues() {
    hostBridgeCapabilityIssues = hostBridgeCapabilityIssues.filter {
      forcedHostBridgeCapabilities.contains($0.key)
    }
  }

  public func markHostBridgeIssue(for capability: String, statusCode: Int) {
    switch statusCode {
    case 501:
      let hostBridge = daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
      if hostBridge.running && hostBridge.capabilities[capability] == nil {
        hostBridgeCapabilityIssues[capability] = .excluded
      } else {
        hostBridgeCapabilityIssues[capability] = .unavailable
      }
    case 503:
      hostBridgeCapabilityIssues[capability] = .unavailable
    default:
      break
    }
  }

  public var codexUnavailable: Bool {
    hostBridgeCapabilityState(for: "codex") != .ready
  }

  public var agentTuiUnavailable: Bool {
    hostBridgeCapabilityState(for: "agent-tui") != .ready
  }
}

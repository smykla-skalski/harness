import HarnessMonitorKit
import Observation
import SwiftUI

extension WorkspaceWindowView {
  protocol KeySequenceClock: AnyObject, Sendable {
    @MainActor var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant) async throws
  }
  final class LiveKeySequenceClock: KeySequenceClock, @unchecked Sendable {
    @MainActor var now: ContinuousClock.Instant { ContinuousClock.now }
    func sleep(until deadline: ContinuousClock.Instant) async throws {
      try await ContinuousClock().sleep(until: deadline)
    }
  }
  @MainActor
  @Observable
  final class KeySequenceBuffer {
    enum EnqueueResult: Equatable {
      case buffered
      case sendImmediately(AgentTuiInputRequest)
    }
    struct PendingStep: Equatable {
      let delayBeforeMs: Int
      let input: AgentTuiInput
      let glyph: String
    }
    private let clock: any KeySequenceClock
    private let idleDelay: Duration
    private var pendingSteps: [PendingStep] = []
    private var lastImmediateInputAt: ContinuousClock.Instant?
    private var lastImmediateTuiID: String?
    private var lastQueuedAt: ContinuousClock.Instant?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var flushHandler:
      (@MainActor (_ tuiID: String, _ request: AgentTuiInputRequest) async -> Void)?
    var pendingHint: String?
    var pendingTuiID: String?
    init(
      clock: any KeySequenceClock = LiveKeySequenceClock(),
      idleDelay: Duration = .milliseconds(350)
    ) {
      self.clock = clock
      self.idleDelay = idleDelay
    }
    deinit {
      flushTask?.cancel()
    }
    var hasPendingInputs: Bool {
      pendingTuiID != nil && !pendingSteps.isEmpty
    }
    @discardableResult
    func enqueue(
      input: AgentTuiInput,
      glyph: String,
      tuiID: String,
      onFlush: @escaping @MainActor (_ tuiID: String, _ request: AgentTuiInputRequest) async -> Void
    ) -> EnqueueResult {
      if let pendingTuiID, pendingTuiID != tuiID {
        clearAllState()
      }
      let now = clock.now
      if shouldSendImmediately(to: tuiID, now: now) {
        lastImmediateInputAt = now
        lastImmediateTuiID = tuiID
        return .sendImmediately(AgentTuiInputRequest(input: input))
      }
      let delayBeforeMs =
        if let lastQueuedAt, !pendingSteps.isEmpty {
          Self.durationMilliseconds(lastQueuedAt.duration(to: now))
        } else if let lastImmediateInputAt, lastImmediateTuiID == tuiID {
          Self.durationMilliseconds(lastImmediateInputAt.duration(to: now))
        } else {
          0
        }
      pendingSteps.append(
        PendingStep(
          delayBeforeMs: delayBeforeMs,
          input: input,
          glyph: glyph
        )
      )
      pendingTuiID = tuiID
      pendingHint = pendingSteps.map(\.glyph).joined()
      lastQueuedAt = now
      flushHandler = onFlush
      scheduleIdleFlush()
      return .buffered
    }
    func flush() async {
      let flushHandler = flushHandler
      guard let pending = takePendingRequest(), let flushHandler else {
        return
      }
      await flushHandler(pending.tuiID, pending.request)
    }
    func drop() {
      clearAllState()
    }
    private func takePendingRequest() -> (tuiID: String, request: AgentTuiInputRequest)? {
      guard
        let tuiID = pendingTuiID,
        !pendingSteps.isEmpty
      else {
        clearAllState()
        return nil
      }
      let request: AgentTuiInputRequest?
      if pendingSteps.count == 1, let step = pendingSteps.first {
        request = AgentTuiInputRequest(input: step.input)
      } else {
        let steps = pendingSteps.enumerated().map { index, step in
          AgentTuiInputSequenceStep(
            delayBeforeMs: index == 0 ? 0 : step.delayBeforeMs,
            input: step.input
          )
        }
        request = try? AgentTuiInputRequest(
          sequence: AgentTuiInputSequence(steps: steps)
        )
      }
      clearPendingState()
      clearBurstState()
      guard let request else {
        return nil
      }
      return (tuiID, request)
    }
    private func scheduleIdleFlush() {
      flushTask?.cancel()
      let deadline = clock.now.advanced(by: idleDelay)
      flushTask = Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          try await clock.sleep(until: deadline)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        await flush()
      }
    }
    private func shouldSendImmediately(
      to tuiID: String,
      now: ContinuousClock.Instant
    ) -> Bool {
      guard pendingSteps.isEmpty else {
        return false
      }
      guard let lastImmediateInputAt, lastImmediateTuiID == tuiID else {
        return true
      }
      return now >= lastImmediateInputAt.advanced(by: idleDelay)
    }
    private func clearPendingState() {
      flushTask?.cancel()
      flushTask = nil
      pendingSteps = []
      pendingHint = nil
      pendingTuiID = nil
      lastQueuedAt = nil
      flushHandler = nil
    }
    private func clearBurstState() {
      lastImmediateInputAt = nil
      lastImmediateTuiID = nil
    }
    private func clearAllState() {
      clearPendingState()
      clearBurstState()
    }
    private static func durationMilliseconds(_ duration: Duration) -> Int {
      max(0, Int(duration.components.seconds * 1_000))
        + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
  }
  enum Field: Hashable {
    case name
    case prompt
    case argv
    case input
  }
  struct AgentNameMapping: Equatable {
    let agentID: String
    let name: String
  }
  struct AgentTuiDisplayState: Equatable {
    let sortedAgentTuis: [AgentTuiSnapshot]
    let sessionTitlesByID: [String: String]
    let sortedCodexRuns: [CodexRunSnapshot]
    let codexTitlesByID: [String: String]
    let externalAgents: [AgentRegistration]
    var hasAgentTuis: Bool {
      !sortedAgentTuis.isEmpty
    }
    var hasCodexRuns: Bool {
      !sortedCodexRuns.isEmpty
    }
    var hasExternalAgents: Bool {
      !externalAgents.isEmpty
    }
    init() {
      sortedAgentTuis = []
      sessionTitlesByID = [:]
      sortedCodexRuns = []
      codexTitlesByID = [:]
      externalAgents = []
    }

    @MainActor
    init(
      store: HarnessMonitorStore,
      includeActiveAgentTuis: Bool = true,
      includeActiveCodexRuns: Bool = true
    ) {
      let agentTuis = store.selectedAgentTuis.sorted { left, right in
        if left.status.sortPriority != right.status.sortPriority {
          return left.status.sortPriority < right.status.sortPriority
        }
        if left.runtime != right.runtime {
          return left.runtime < right.runtime
        }
        return left.tuiId < right.tuiId
      }
      let codexRuns = store.selectedCodexRuns.sorted { left, right in
        if left.status.isActive != right.status.isActive {
          return left.status.isActive && !right.status.isActive
        }
        if left.mode != right.mode {
          return left.mode.rawValue < right.mode.rawValue
        }
        if left.createdAt != right.createdAt {
          return left.createdAt > right.createdAt
        }
        return left.runId < right.runId
      }
      let sortedAgentTuis =
        includeActiveAgentTuis ? agentTuis : agentTuis.filter { !$0.status.isActive }
      let sortedCodexRuns =
        includeActiveCodexRuns ? codexRuns : codexRuns.filter { !$0.status.isActive }
      var codexTitlesByID: [String: String] = [:]
      codexTitlesByID.reserveCapacity(sortedCodexRuns.count)
      for run in sortedCodexRuns {
        codexTitlesByID[run.runId] = Self.codexTitle(for: run)
      }
      let agentNames = Dictionary(
        uniqueKeysWithValues: (store.selectedSession?.agents ?? []).map { ($0.agentId, $0.name) }
      )
      var sessionTitlesByID: [String: String] = [:]
      sessionTitlesByID.reserveCapacity(sortedAgentTuis.count)
      for tui in sortedAgentTuis {
        sessionTitlesByID[tui.tuiId] =
          agentNames[tui.agentId] ?? WorkspaceWindowView.runtimeTitle(for: tui)
      }
      let externalAgents = (store.selectedSession?.agents ?? [])
        .sorted { left, right in
          if left.name != right.name {
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
          }
          return left.agentId < right.agentId
        }
      self.sortedAgentTuis = sortedAgentTuis
      self.sessionTitlesByID = sessionTitlesByID
      self.sortedCodexRuns = sortedCodexRuns
      self.codexTitlesByID = codexTitlesByID
      self.externalAgents = externalAgents
    }

    /// Hold back active managed items until the first refresh completes so reopening the window
    /// cannot render stale live sessions from cached store state.
    @MainActor
    init(initialWindowStore store: HarnessMonitorStore) {
      self.init(
        store: store,
        includeActiveAgentTuis: false,
        includeActiveCodexRuns: false
      )
    }
    static func codexTitle(for run: CodexRunSnapshot) -> String {
      let promptSummary =
        run.prompt
        .split(whereSeparator: \.isNewline)
        .first
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .flatMap { normalized in
          normalized.isEmpty ? nil : normalized
        }
        ?? "Codex run"
      let clippedPrompt = String(promptSummary.prefix(45))
      return "Codex · \(run.mode.title) · \(clippedPrompt)"
    }
  }
  enum AgentTuiInputMode: String, CaseIterable, Identifiable {
    case text
    case paste
    var id: String { rawValue }
    var title: String {
      switch self {
      case .text:
        "Type"
      case .paste:
        "Paste"
      }
    }
  }
  @MainActor
  @Observable
  final class ViewModel {
    var runtime: AgentTuiRuntime
    var selectedLaunchSelection: AgentLaunchSelection
    var selectedRole: SessionRole = .worker
    var selectedAcpFallbackRole: SessionRole = .worker
    var name = ""
    var prompt = ""
    var projectDir = ""
    var argvOverride = ""
    var inputText = ""
    var inputMode: AgentTuiInputMode = .text
    var rows = 32
    var cols = 120
    var isSubmitting = false
    var selection: WorkspaceSelection = .create
    var createSessionID: String?
    var wrapLines = false
    var selectedPersona: String?
    var selectedPersonaID: String {
      get { selectedPersona ?? "" }
      set { selectedPersona = newValue.isEmpty ? nil : newValue }
    }
    var availablePersonas: [AgentPersona] = []
    var availableRuntimeModels: [RuntimeModelCatalog] = []
    var availableAcpAgents: [AcpAgentDescriptor] = []
    var runtimeProbeResults: AcpRuntimeProbeResponse?
    var selectedTerminalModelByRuntime: [AgentTuiRuntime: String] = [:]
    var selectedCodexModel: String?
    var selectedTerminalEffortByRuntime: [AgentTuiRuntime: String] = [:]
    var selectedCodexEffort: String?
    /// Per-runtime custom model id entered in the "Custom..." text field.
    /// `nil` when the picker is on a catalog model; a non-empty string when
    /// the user typed a custom id and toggled the escape hatch.
    var customTerminalModelByRuntime: [AgentTuiRuntime: String] = [:]
    var customCodexModel: String?
    var createMode: AgentTuiCreateMode = .terminal
    var codexPrompt = ""
    var codexMode: CodexRunMode = .report
    var codexContext = ""
    var startTuiAttemptCount = 0
    var startTuiPhase = "idle"
    var codexStartAttemptCount = 0
    var codexStartResult = "idle"
    var resolvingCodexApprovalID: String?
    var navigationBackStack: [WorkspaceSelection] = []
    var navigationForwardStack: [WorkspaceSelection] = []
    var suppressHistoryRecording = false
    var windowNavigation = WindowNavigationState()
    @ObservationIgnored var lastMeasuredViewportPoints: CGSize?
    @ObservationIgnored var lastMeasuredViewportTerminalSize: AgentTuiSize?
    @ObservationIgnored var pendingViewportResizeTarget: AgentTuiSize?
    @ObservationIgnored var lastMeasuredViewportSize: AgentTuiSize?
    @ObservationIgnored var viewportResizeTask: Task<Void, Never>?
    @ObservationIgnored var expectedSize: AgentTuiSize?
    var keySequenceBuffer = KeySequenceBuffer()
    var hasFreshManagedAgentTuis = false
    var hasFreshManagedCodexRuns = false
    var displayState: AgentTuiDisplayState
    init(
      selection: WorkspaceSelection = .create,
      displayState: AgentTuiDisplayState = AgentTuiDisplayState(),
      createSessionID: String? = nil
    ) {
      let preferredLaunchSelection = HarnessMonitorAgentLaunchDefaults.preferredSelection()
      runtime = preferredLaunchSelection.preferredRuntime
      selectedLaunchSelection = preferredLaunchSelection
      self.selection = selection
      self.createSessionID = createSessionID ?? selection.sessionID
      self.displayState = displayState
    }
  }
}

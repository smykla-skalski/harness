import AppKit
import HarnessMonitorKit
import Observation
import SwiftUI
extension AgentTuiWindowView {
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
    let agentTuiUnavailable: Bool
    let codexUnavailable: Bool
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
      agentTuiUnavailable = false
      codexUnavailable = false
    }
    @MainActor
    init(store: HarnessMonitorStore) {
      let sortedAgentTuis = store.selectedAgentTuis.sorted { left, right in
        if left.status.sortPriority != right.status.sortPriority {
          return left.status.sortPriority < right.status.sortPriority
        }
        if left.runtime != right.runtime {
          return left.runtime < right.runtime
        }
        return left.tuiId < right.tuiId
      }
      let sortedCodexRuns = store.selectedCodexRuns.sorted { left, right in
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
          agentNames[tui.agentId] ?? AgentTuiWindowView.runtimeTitle(for: tui)
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
      self.agentTuiUnavailable = store.agentTuiUnavailable
      self.codexUnavailable = store.codexUnavailable
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
  enum TerminalViewportSizing {
    static let rowRange = 8...240
    static let colRange = 20...400
    static let minimumViewportHeight: CGFloat = 220
    static let idealViewportHeight: CGFloat = 320
    static let minimumControlsHeight: CGFloat = 220
    static let minimumMeasuredContentWidth: CGFloat = 160
    static let minimumMeasuredContentHeight: CGFloat = 96
    static let debounce = Duration.milliseconds(120)
    static let automaticResizeMinimumRowDelta = 2
    static let automaticResizeMinimumColDelta = 3
    static let contentInsets = CGSize(
      width: HarnessMonitorTheme.spacingMD * 2,
      height: HarnessMonitorTheme.spacingMD * 2
    )
    @MainActor
    static func terminalSize(for viewportSize: CGSize, fontScale: CGFloat) -> AgentTuiSize? {
      let cellSize = measuredCellSize(for: fontScale)
      let usableWidth = viewportSize.width - contentInsets.width
      let usableHeight = viewportSize.height - contentInsets.height
      guard usableWidth >= minimumMeasuredContentWidth,
        usableHeight >= minimumMeasuredContentHeight
      else {
        return nil
      }
      let rawRows = Int(floor(usableHeight / cellSize.height))
      let rawCols = Int(floor(usableWidth / cellSize.width))
      guard rawRows > 0, rawCols > 0 else {
        return nil
      }
      return AgentTuiSize(
        rows: min(max(rawRows, rowRange.lowerBound), rowRange.upperBound),
        cols: min(max(rawCols, colRange.lowerBound), colRange.upperBound)
      )
    }
    static func stabilizedAutomaticSize(
      measured: AgentTuiSize,
      baseline: AgentTuiSize
    ) -> AgentTuiSize {
      AgentTuiSize(
        rows: stabilizedDimension(
          measured: measured.rows,
          baseline: baseline.rows,
          minimumDelta: automaticResizeMinimumRowDelta
        ),
        cols: stabilizedDimension(
          measured: measured.cols,
          baseline: baseline.cols,
          minimumDelta: automaticResizeMinimumColDelta
        )
      )
    }
    @MainActor
    private static func measuredCellSize(for fontScale: CGFloat) -> CGSize {
      let pointSize = 13 * max(fontScale, 0.78)
      let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
      let width = max(
        ceil(("W" as NSString).size(withAttributes: [.font: font]).width),
        1
      )
      let height = max(ceil(font.ascender - font.descender + font.leading), 1)
      return CGSize(width: width, height: height)
    }
    private static func stabilizedDimension(
      measured: Int,
      baseline: Int,
      minimumDelta: Int
    ) -> Int {
      abs(measured - baseline) >= minimumDelta ? measured : baseline
    }
  }
  @MainActor
  @Observable
  final class ViewModel {
    var runtime: AgentTuiRuntime = .copilot
    var selectedRole: SessionRole = .worker
    var name = ""
    var prompt = ""
    var projectDir = ""
    var argvOverride = ""
    var inputText = ""
    var inputMode: AgentTuiInputMode = .text
    var rows = 32
    var cols = 120
    var isSubmitting = false
    var selection: AgentTuiSheetSelection = .create
    var wrapLines = false
    var selectedPersona: String?
    var availablePersonas: [AgentPersona] = []
    var availableRuntimeModels: [RuntimeModelCatalog] = []
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
    var resolvingCodexApprovalID: String?
    var navigationBackStack: [AgentTuiSheetSelection] = []
    var navigationForwardStack: [AgentTuiSheetSelection] = []
    var suppressHistoryRecording = false
    var windowNavigation = WindowNavigationState()
    var pendingViewportResizeTarget: AgentTuiSize?
    var viewportResizeTask: Task<Void, Never>?
    var expectedSize: AgentTuiSize?
    var keySequenceBuffer = KeySequenceBuffer()
    init(
      selection: AgentTuiSheetSelection = .create
    ) {
      self.selection = selection
    }
  }
}

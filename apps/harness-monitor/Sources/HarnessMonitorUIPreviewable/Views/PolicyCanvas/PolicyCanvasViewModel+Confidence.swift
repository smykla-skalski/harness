import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

/// One row of the always-on decision matrix: how the current draft resolves a
/// single policy action under the latest simulation. Identifiable by scenario
/// plus action because editable scenarios can exercise the same action more than
/// once. Carries only value types so the matrix views never depend on the wire
/// model.
struct PolicyCanvasDecisionMatrixRowModel: Identifiable, Equatable {
  let id: String
  let scenarioName: String
  let actionRaw: String
  let actionTitle: String
  let verdict: PolicyCanvasDecisionVerdict
  let reasonCode: String
  let visitedNodeIds: [String]
}

/// The five terminal verdicts the daemon emits, plus an `unknown` escape hatch
/// for strings we do not recognise. Richer than the binary allowed/denied the
/// canvas overlay uses, so the matrix can tell needs-human from deny.
enum PolicyCanvasDecisionVerdict: Equatable {
  case allow
  case needsHuman
  case deny
  case consensus
  case dryRun
  case unknown(String)

  init(decisionString: String) {
    switch decisionString {
    case "allow":
      self = .allow
    case "deny":
      self = .deny
    case "require_human":
      self = .needsHuman
    case "require_consensus":
      self = .consensus
    case "dry_run_only":
      self = .dryRun
    default:
      self = .unknown(decisionString)
    }
  }

  /// Map the generated `PolicyDecision` tagged enum straight to a verdict. Used by
  /// the go-live diff, which carries `PolicyDecision` directly rather than the
  /// flattened `TaskBoardPolicyDecision` the simulate result uses.
  init(decision: PolicyDecision) {
    switch decision {
    case .allow:
      self = .allow
    case .deny:
      self = .deny
    case .requireHuman:
      self = .needsHuman
    case .requireConsensus:
      self = .consensus
    case .dryRunOnly:
      self = .dryRun
    }
  }

  var label: String {
    switch self {
    case .allow:
      return "Allow"
    case .needsHuman:
      return "Needs human"
    case .deny:
      return "Deny"
    case .consensus:
      return "Consensus"
    case .dryRun:
      return "Dry run"
    case .unknown(let raw):
      return raw.replacingOccurrences(of: "_", with: " ")
    }
  }
}

extension PolicyCanvasViewModel {
  /// Count of error-severity validation issues. Re-introduced for the
  /// confidence panel after Phase 2 dropped the workflow-status machinery.
  var validationErrorCount: Int {
    allValidationIssues.filter { $0.severity == .error }.count
  }

  /// Count of warning-severity validation issues.
  var validationWarningCount: Int {
    allValidationIssues.filter { $0.severity == .warning }.count
  }

  /// Decision-matrix rows projected from the latest simulation. Empty when no
  /// simulation has run or it failed end-to-end (the validation panel carries
  /// the errors in that case). A plain computed projection - 13 actions is
  /// small enough that a token cache is not worth a stored slot on the model.
  var decisionMatrixRows: [PolicyCanvasDecisionMatrixRowModel] {
    guard let simulation = latestSimulation, simulation.succeeded else {
      return []
    }
    return simulation.decisions.map { decision in
      let scenarioID =
        decision.scenarioId.isEmpty ? decision.scenarioName : decision.scenarioId
      return PolicyCanvasDecisionMatrixRowModel(
        id: "\(scenarioID).\(decision.action.rawValue)",
        scenarioName: decision.scenarioName,
        actionRaw: decision.action.rawValue,
        actionTitle: decision.action.policyCanvasTitle,
        verdict: PolicyCanvasDecisionVerdict(decisionString: decision.decision.decision),
        reasonCode: decision.decision.reasonCode,
        visitedNodeIds: decision.visitedNodeIds
      )
    }
  }

  /// Quiet window with no further edits before a confidence simulation runs.
  /// Slightly longer than the autosave quiet window so the draft is usually
  /// saved (and clean) by the time the simulation runs against it.
  static let confidenceQuietWindowMilliseconds: UInt64 = 900

  /// Ceiling on the adaptive confidence wait - run even if edits keep coming.
  static let confidenceMaxWindowMilliseconds: UInt64 = 2_800

  /// Cancel any in-flight confidence task.
  func cancelConfidenceEvaluation() {
    confidenceTask?.cancel()
    confidenceTask = nil
  }

  /// Schedule a debounced confidence run. Each call supersedes the previous, so
  /// an edit burst collapses to one simulation once edits settle. The `perform`
  /// closure runs the same daemon simulate path the old Simulate button used, so
  /// the view model stays daemon-agnostic. Skips when a simulation is already in
  /// flight (the debounce keeps runs from stacking).
  func scheduleConfidenceEvaluation(perform: @escaping @MainActor () -> Void) {
    cancelConfidenceEvaluation()
    confidenceTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      await self.waitForConfidenceQuietWindow()
      guard !Task.isCancelled, !self.isSimulating else {
        return
      }
      perform()
    }
  }

  /// Sleep in quiet-window chunks until `documentGeneration` stops advancing
  /// (edits settled) or the ceiling elapses. Mirrors the autosave adaptive
  /// window so a drag that fires `markDocumentDirty()` at ~60Hz still collapses
  /// to a single run.
  private func waitForConfidenceQuietWindow() async {
    let quiet = Self.confidenceQuietWindowMilliseconds
    var elapsed: UInt64 = 0
    var lastGeneration = documentGeneration
    while !Task.isCancelled, elapsed < Self.confidenceMaxWindowMilliseconds {
      try? await Task.sleep(for: .milliseconds(Int(quiet)))
      elapsed &+= quiet
      let current = documentGeneration
      if current == lastGeneration {
        return
      }
      lastGeneration = current
    }
  }
}

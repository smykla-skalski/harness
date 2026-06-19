import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

/// One row of the always-on decision matrix: how the current draft resolves a
/// single policy action under the latest simulation. Identifiable by the raw
/// action string (each action appears at most once per simulation). Carries
/// only value types so the matrix views never depend on the wire model.
struct PolicyCanvasDecisionMatrixRowModel: Identifiable, Equatable {
  let actionRaw: String
  let actionTitle: String
  let verdict: PolicyCanvasDecisionVerdict
  let reasonCode: String
  let visitedNodeIds: [String]

  var id: String { actionRaw }
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
      PolicyCanvasDecisionMatrixRowModel(
        actionRaw: decision.action.rawValue,
        actionTitle: decision.action.policyCanvasTitle,
        verdict: PolicyCanvasDecisionVerdict(decisionString: decision.decision.decision),
        reasonCode: decision.decision.reasonCode,
        visitedNodeIds: decision.visitedNodeIds
      )
    }
  }
}

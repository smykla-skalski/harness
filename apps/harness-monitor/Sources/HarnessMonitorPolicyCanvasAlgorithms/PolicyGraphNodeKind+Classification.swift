import HarnessMonitorPolicyModels

// Case-based classification for the wire node-kind enum. Canvas code used to
// branch on the flat `kind.kind == "ocr_image"` discriminator string; these
// helpers replace those string guards with faithful pattern matches so the
// snake_case tokens live only inside the generated decoder.
extension PolicyGraphNodeKind {
  public var isHub: Bool {
    if case .hub = self { return true }
    return false
  }

  public var isOCRImage: Bool {
    if case .ocrImage = self { return true }
    return false
  }

  public var isReviewScreenshotPaste: Bool {
    if case .reviewScreenshotPaste = self { return true }
    return false
  }

  public var isResolveReviewPullRequests: Bool {
    if case .resolveReviewPullRequests = self { return true }
    return false
  }

  public var isCopyReviewPullRequestList: Bool {
    if case .copyReviewPullRequestList = self { return true }
    return false
  }

  public var isDryRunGate: Bool {
    if case .dryRunGate = self { return true }
    return false
  }

  /// The snake_case serde tag for this kind - the same discriminator the
  /// generated encoder writes. Read-only on purpose: it exists so string-keyed
  /// UI (the kind Picker) can round-trip a selection without reaching for the
  /// removed flat `.kind` field, not as a back door to mutate the kind.
  public var discriminator: String {
    switch self {
    case .trigger: return "trigger"
    case .workflowEntry: return "workflow_entry"
    case .actionGate: return "action_gate"
    case .actionStep: return "action_step"
    case .evidenceCheck: return "evidence_check"
    case .ifThenElse: return "if_then_else"
    case .switch: return "switch"
    case .riskClassifier: return "risk_classifier"
    case .waitStep: return "wait_step"
    case .eventWait: return "event_wait"
    case .handoff: return "handoff"
    case .hub: return "hub"
    case .humanGate: return "human_gate"
    case .consensusGate: return "consensus_gate"
    case .dryRunGate: return "dry_run_gate"
    case .supervisorRule: return "supervisor_rule"
    case .finish: return "finish"
    case .reviewScreenshotPaste: return "review_screenshot_paste"
    case .ocrImage: return "ocr_image"
    case .resolveReviewPullRequests: return "resolve_review_pull_requests"
    case .copyReviewPullRequestList: return "copy_review_pull_request_list"
    }
  }
}

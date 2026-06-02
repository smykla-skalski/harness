import HarnessMonitorKit

extension PolicyCanvasNodeKind {
  static let trigger = Self(
    rawValue: "trigger",
    title: "Trigger",
    subtitle: "Workflow trigger",
    symbolName: "bolt.horizontal.circle",
    category: .source,
    librarySection: .sources,
    inputPortTitles: [],
    outputPortTitles: ["event"],
    libraryTitle: "Workflow trigger",
    librarySubtitle: "Start from a default workflow trigger",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(kind: "trigger", workflow: "default-task")
  )

  static let workflowEntry = Self(
    rawValue: "workflow_entry",
    title: "Workflow entry",
    subtitle: "Named workflow entry",
    symbolName: "point.3.connected.trianglepath.dotted",
    category: .source,
    librarySection: .sources,
    inputPortTitles: [],
    outputPortTitles: ["out"],
    libraryTitle: "Workflow entry",
    librarySubtitle: "Start a named policy workflow",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(
      kind: "workflow_entry",
      workflowId: "reviews_auto"
    )
  )

  static let reviewScreenshotPaste = Self(
    rawValue: "review_screenshot_paste",
    title: "Review Screenshot Paste",
    subtitle: "GitHub PR rows from screenshots",
    symbolName: "camera.viewfinder",
    category: .source,
    librarySection: .sources,
    inputPortTitles: [],
    outputPortTitles: ["image"],
    libraryTitle: "Reviews screenshot source",
    librarySubtitle: "Start from a Reviews screenshot paste",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(kind: "review_screenshot_paste")
  )

  static let actionGate = Self(
    rawValue: "action_gate",
    title: "Action gate",
    subtitle: "Route by requested action",
    symbolName: "arrow.branch",
    category: .condition,
    librarySection: .conditions,
    inputPortTitles: ["in"],
    outputPortTitles: ["match", "default"],
    libraryTitle: "Action gate",
    librarySubtitle: "Branch by requested action",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(
      kind: "action_gate",
      actions: [.submitReview]
    )
  )

  static let evidenceCheck = Self(
    rawValue: "evidence_check",
    title: "Evidence check",
    subtitle: "Evaluate policy evidence",
    symbolName: "checklist",
    category: .condition,
    librarySection: .conditions,
    inputPortTitles: ["in"],
    outputPortTitles: ["pass", "fail", "missing"],
    libraryTitle: "Evidence check",
    librarySubtitle: "Branch on policy evidence",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(
      kind: "evidence_check",
      checks: [
        TaskBoardPolicyEvidenceCheck(
          field: .reviewIsOpen,
          pass: TaskBoardPolicyEvidencePredicate(predicate: .isTrue),
          failReasonCode: PolicyCanvasReasonCode.missingMergeEvidence,
          missingReasonCode: PolicyCanvasReasonCode.missingMergeEvidence
        )
      ]
    )
  )

  static let ifThenElse = Self(
    rawValue: "if_then_else",
    title: "If / then / else",
    subtitle: "Branch on a boolean condition",
    symbolName: "diamond",
    category: .condition,
    accentStyle: .activeTint,
    librarySection: .conditions,
    inputPortTitles: ["in"],
    outputPortTitles: ["then", "else"],
    libraryTitle: "If / then / else",
    librarySubtitle: "Branch on a boolean policy condition",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(
      kind: "if_then_else",
      field: .checksGreen,
      predicate: TaskBoardPolicyEvidencePredicate(predicate: .isTrue)
    )
  )

  static let `switch` = Self(
    rawValue: "switch",
    title: "Switch",
    subtitle: "Route through ordered cases",
    symbolName: "switch.2",
    category: .condition,
    accentStyle: .branchingTint,
    librarySection: .conditions,
    inputPortTitles: ["in"],
    outputPortTitles: ["case_1", "default"],
    libraryTitle: "Switch",
    librarySubtitle: "Route through ordered policy cases",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(
      kind: "switch",
      arms: [
        TaskBoardPolicySwitchArm(
          port: "case_1",
          field: .checksGreen,
          predicate: TaskBoardPolicyEvidencePredicate(predicate: .isTrue)
        )
      ]
    )
  )

  static let riskClassifier = Self(
    rawValue: "risk_classifier",
    title: "Risk classifier",
    subtitle: "Classify risk level",
    symbolName: "gauge.medium",
    category: .condition,
    librarySection: .conditions,
    inputPortTitles: ["in"],
    outputPortTitles: ["low_or_equal", "high", "missing"],
    libraryTitle: "Risk classifier",
    librarySubtitle: "Branch on a risk threshold",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(
      kind: "risk_classifier",
      field: .riskScore,
      threshold: 50,
      highRiskReasonCode: PolicyCanvasReasonCode.riskAboveThreshold,
      missingReasonCode: PolicyCanvasReasonCode.humanRequired
    )
  )

  static let humanGate = Self(
    rawValue: "human_gate",
    title: "Human gate",
    subtitle: "Manual decision required",
    symbolName: "person.badge.shield.checkmark",
    category: .review,
    librarySection: .reviewGates,
    inputPortTitles: ["in"],
    outputPortTitles: [],
    libraryTitle: "Human gate",
    librarySubtitle: "Require a manual review decision",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(kind: "human_gate")
  )

  static let consensusGate = Self(
    rawValue: "consensus_gate",
    title: "Consensus gate",
    subtitle: "Extra approval required",
    symbolName: "person.2.badge.key",
    category: .review,
    librarySection: .reviewGates,
    inputPortTitles: ["in"],
    outputPortTitles: [],
    libraryTitle: "Consensus gate",
    librarySubtitle: "Require extra reviewer consensus",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(kind: "consensus_gate")
  )

  static let actionStep = Self(
    rawValue: "action_step",
    title: "Action step",
    subtitle: "Execute a workflow action",
    symbolName: "play.circle",
    category: .transform,
    librarySection: .orchestration,
    inputPortTitles: ["in"],
    outputPortTitles: ["out"],
    libraryTitle: "Action step",
    librarySubtitle: "Run a provider action",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(
      kind: "action_step",
      actionId: "reviews.approve"
    )
  )

  static let ocrImage = Self(
    rawValue: "ocr_image",
    title: "OCR image",
    subtitle: "Recognize text in screenshots",
    symbolName: "text.viewfinder",
    category: .transform,
    librarySection: .orchestration,
    inputPortTitles: ["in"],
    outputPortTitles: ["text"],
    libraryTitle: "Screenshot OCR",
    librarySubtitle: "Recognize text in a pasted screenshot",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(kind: "ocr_image")
  )

  static let resolveReviewPullRequests = Self(
    rawValue: "resolve_review_pull_requests",
    title: "Resolve Reviews PRs",
    subtitle: "Match extracted PRs to Reviews",
    symbolName: "doc.text.magnifyingglass",
    category: .transform,
    librarySection: .orchestration,
    inputPortTitles: ["in"],
    outputPortTitles: ["pull_requests"],
    libraryTitle: "Reviews PR resolver",
    librarySubtitle: "Resolve screenshot PR rows against Reviews",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(kind: "resolve_review_pull_requests")
  )

  static let copyReviewPullRequestList = Self(
    rawValue: "copy_review_pull_request_list",
    title: "Copy PR list",
    subtitle: "Copy resolved PR output",
    symbolName: "doc.on.clipboard",
    category: .transform,
    librarySection: .orchestration,
    inputPortTitles: ["in"],
    outputPortTitles: [],
    libraryTitle: "PR list copier",
    librarySubtitle: "Copy resolved pull request references",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(kind: "copy_review_pull_request_list")
  )

  static let waitStep = Self(
    rawValue: "wait_step",
    title: "Wait step",
    subtitle: "Pause until a timer or event",
    symbolName: "hourglass.circle",
    category: .transform,
    librarySection: .orchestration,
    inputPortTitles: ["in"],
    outputPortTitles: ["out"],
    libraryTitle: "Wait step",
    librarySubtitle: "Pause until a timer or event resumes the workflow",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(
      kind: "wait_step",
      wait: .event("reviews.checks_passed"),
      resumeKey: "checks-ready"
    )
  )

  static let eventWait = Self(
    rawValue: "event_wait",
    title: "Event wait",
    subtitle: "Observe a workflow event",
    symbolName: "bolt.badge.clock",
    category: .transform,
    librarySection: .orchestration,
    inputPortTitles: ["in"],
    outputPortTitles: ["out"],
    libraryTitle: "Event wait",
    librarySubtitle: "Listen for an event in the workflow graph",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(
      kind: "event_wait",
      eventKey: "reviews.checks_passed"
    )
  )

  static let handoff = Self(
    rawValue: "handoff",
    title: "Handoff",
    subtitle: "Hand off to another handler",
    symbolName: "arrow.triangle.branch",
    category: .transform,
    librarySection: .orchestration,
    inputPortTitles: ["in"],
    outputPortTitles: ["out"],
    libraryTitle: "Handoff",
    librarySubtitle: "Pass control to another workflow handler",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(
      kind: "handoff",
      handoffKey: "next-handler"
    )
  )

  static let dryRunGate = Self(
    rawValue: "dry_run_gate",
    title: "Dry-run gate",
    subtitle: "Stop outside enforced mode",
    symbolName: "testtube.2",
    category: .decision,
    librarySection: .outcomes,
    inputPortTitles: ["in"],
    outputPortTitles: [],
    libraryTitle: "Dry-run gate",
    librarySubtitle: "End the workflow in dry run",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(kind: "dry_run_gate")
  )

  static let supervisorRule = Self(
    rawValue: "supervisor_rule",
    title: "Supervisor rule",
    subtitle: "Apply supervisor policy",
    symbolName: "checkmark.shield",
    category: .decision,
    librarySection: .outcomes,
    inputPortTitles: ["in"],
    outputPortTitles: [],
    libraryTitle: "Supervisor rule",
    librarySubtitle: "Finish with a supervisor decision",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(
      kind: "supervisor_rule",
      ruleId: "stuck-agent"
    )
  )

  static let finish = Self(
    rawValue: "finish",
    title: "Finish",
    subtitle: "Terminal workflow decision",
    symbolName: "flag.checkered",
    category: .decision,
    librarySection: .outcomes,
    inputPortTitles: ["in"],
    outputPortTitles: [],
    libraryTitle: "Finish",
    librarySubtitle: "End the workflow with a final decision",
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind(
      kind: "finish",
      reasonCode: PolicyCanvasReasonCode.autoMergeAllowed,
      decision: "allow"
    )
  )

  static let allCases: [Self] = [
    .trigger,
    .workflowEntry,
    .reviewScreenshotPaste,
    .actionGate,
    .evidenceCheck,
    .ifThenElse,
    .switch,
    .riskClassifier,
    .humanGate,
    .consensusGate,
    .actionStep,
    .ocrImage,
    .resolveReviewPullRequests,
    .copyReviewPullRequestList,
    .waitStep,
    .eventWait,
    .handoff,
    .dryRunGate,
    .supervisorRule,
    .finish,
  ]

  private static let legacyAuthoringKinds: Set<Self> = [
    .actionGate,
    .evidenceCheck,
    .riskClassifier,
  ]

  static func authoringCases(including current: Self? = nil) -> [Self] {
    var kinds = allCases.filter { !legacyAuthoringKinds.contains($0) }
    if let current, legacyAuthoringKinds.contains(current) {
      kinds.append(current)
    }
    return kinds
  }

  static let lookup = Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0) })

  // Legacy aliases used by older sample/test helpers until they are fully
  // migrated onto the richer workflow vocabulary.
  static let source = trigger
  static let condition = ifThenElse
  static let review = humanGate
  static let transform = actionStep
  static let decision = finish
}

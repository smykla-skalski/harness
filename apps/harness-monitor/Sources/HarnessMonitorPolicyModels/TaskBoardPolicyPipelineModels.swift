import Foundation

public enum TaskBoardPolicyAction: String, Codable, CaseIterable, Identifiable, Sendable {
  case sync
  case triage
  case plan
  case spawnAgent = "spawn_agent"
  case mutateRepo = "mutate_repo"
  case pushBranch = "push_branch"
  case openPr = "open_pr"
  case submitReview = "submit_review"
  case mergePr = "merge_pr"
  case deleteWorktree = "delete_worktree"
  case stopAgent = "stop_agent"
  case accessSecret = "access_secret"
  case destructiveFs = "destructive_fs"

  public var id: String { rawValue }
}

public enum TaskBoardPolicyEvidenceField: String, Codable, CaseIterable, Sendable {
  case checksGreen = "checks_green"
  case branchProtectionAllowsMerge = "branch_protection_allows_merge"
  case reviewerVerdictApproved = "reviewer_verdict_approved"
  case unresolvedRequestedChanges = "unresolved_requested_changes"
  case protectedPathTouched = "protected_path_touched"
  case riskScore = "risk_score"
  case reviewIsOpen = "review_is_open"
  case reviewIsDraft = "review_is_draft"
  case reviewReviewRequired = "review_review_required"
  case reviewHasNoDecision = "review_has_no_decision"
  case reviewHasMergeConflicts = "review_has_merge_conflicts"
  case reviewPolicyBlocked = "review_policy_blocked"
  case reviewViewerCanUpdate = "review_viewer_can_update"
}

public struct TaskBoardPolicyPipelineAutomationBinding: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var eventSource: String
  public var priority: Int?
  public var contentKinds: [String]
  public var preprocessors: [String]
  public var actions: [String]
  public var postprocessors: [String]
  public var sourceAppMode: String
  public var allowedBundleIdentifiers: [String]
  public var deniedBundleIdentifiers: [String]
  public var ocrConfiguration: TaskBoardPolicyPipelineOCRConfiguration?
  public var reviewPullRequestExtraction: TaskBoardPolicyPipelineReviewPullRequestExtraction?

  public init(
    isEnabled: Bool = true,
    eventSource: String,
    priority: Int? = nil,
    contentKinds: [String] = [],
    preprocessors: [String] = [],
    actions: [String] = [],
    postprocessors: [String] = [],
    sourceAppMode: String = "allExceptDenied",
    allowedBundleIdentifiers: [String] = [],
    deniedBundleIdentifiers: [String] = [],
    ocrConfiguration: TaskBoardPolicyPipelineOCRConfiguration? = nil,
    reviewPullRequestExtraction: TaskBoardPolicyPipelineReviewPullRequestExtraction? = nil
  ) {
    self.isEnabled = isEnabled
    self.eventSource = eventSource
    self.priority = priority
    self.contentKinds = contentKinds
    self.preprocessors = preprocessors
    self.actions = actions
    self.postprocessors = postprocessors
    self.sourceAppMode = sourceAppMode
    self.allowedBundleIdentifiers = allowedBundleIdentifiers
    self.deniedBundleIdentifiers = deniedBundleIdentifiers
    self.ocrConfiguration = ocrConfiguration
    self.reviewPullRequestExtraction = reviewPullRequestExtraction
  }

  enum CodingKeys: String, CodingKey {
    case isEnabled
    case eventSource
    case priority
    case contentKinds
    case preprocessors
    case actions
    case postprocessors
    case sourceAppMode
    case allowedBundleIdentifiers
    case deniedBundleIdentifiers
    case ocrConfiguration
    case reviewPullRequestExtraction
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    eventSource = try container.decodeIfPresent(String.self, forKey: .eventSource) ?? "clipboard"
    priority = try container.decodeIfPresent(Int.self, forKey: .priority)
    contentKinds = try container.decodeIfPresent([String].self, forKey: .contentKinds) ?? []
    preprocessors = try container.decodeIfPresent([String].self, forKey: .preprocessors) ?? []
    actions = try container.decodeIfPresent([String].self, forKey: .actions) ?? []
    postprocessors = try container.decodeIfPresent([String].self, forKey: .postprocessors) ?? []
    sourceAppMode =
      try container.decodeIfPresent(String.self, forKey: .sourceAppMode) ?? "allExceptDenied"
    allowedBundleIdentifiers =
      try container.decodeIfPresent([String].self, forKey: .allowedBundleIdentifiers) ?? []
    deniedBundleIdentifiers =
      try container.decodeIfPresent([String].self, forKey: .deniedBundleIdentifiers) ?? []
    ocrConfiguration = try container.decodeIfPresent(
      TaskBoardPolicyPipelineOCRConfiguration.self,
      forKey: .ocrConfiguration
    )
    reviewPullRequestExtraction = try container.decodeIfPresent(
      TaskBoardPolicyPipelineReviewPullRequestExtraction.self,
      forKey: .reviewPullRequestExtraction
    )
  }
}

public struct TaskBoardPolicyPipelineOCRConfiguration: Codable, Equatable, Sendable {
  public var recognitionLevel: String
  public var automaticallyDetectsLanguage: Bool
  public var usesLanguageCorrection: Bool

  public init(
    recognitionLevel: String = "accurate",
    automaticallyDetectsLanguage: Bool = true,
    usesLanguageCorrection: Bool = true
  ) {
    self.recognitionLevel = recognitionLevel
    self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
    self.usesLanguageCorrection = usesLanguageCorrection
  }
}

public struct TaskBoardPolicyPipelineReviewPullRequestExtraction: Codable, Equatable, Sendable {
  public var repositoryMode: String
  public var policyRepositories: [String]
  public var numberMemoryEnabled: Bool
  public var resultScope: String
  public var failureSignalMode: String
  public var outputFormat: String
  public var autoCopy: Bool
  public var showSheet: Bool

  public init(
    repositoryMode: String = "allConfiguredRepos",
    policyRepositories: [String] = [],
    numberMemoryEnabled: Bool = true,
    resultScope: String = "all",
    failureSignalMode: String = "liveOrVisual",
    outputFormat: String = "newlineGitHubURLs",
    autoCopy: Bool = true,
    showSheet: Bool = true
  ) {
    self.repositoryMode = repositoryMode
    self.policyRepositories = policyRepositories
    self.numberMemoryEnabled = numberMemoryEnabled
    self.resultScope = resultScope
    self.failureSignalMode = failureSignalMode
    self.outputFormat = outputFormat
    self.autoCopy = autoCopy
    self.showSheet = showSheet
  }

  enum CodingKeys: String, CodingKey {
    case repositoryMode
    case policyRepositories
    case numberMemoryEnabled
    case resultScope
    case failureSignalMode
    case outputFormat
    case autoCopy
    case showSheet
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    repositoryMode =
      try container.decodeIfPresent(String.self, forKey: .repositoryMode) ?? "allConfiguredRepos"
    policyRepositories =
      try container.decodeIfPresent([String].self, forKey: .policyRepositories) ?? []
    numberMemoryEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .numberMemoryEnabled) ?? true
    resultScope = try container.decodeIfPresent(String.self, forKey: .resultScope) ?? "all"
    failureSignalMode =
      try container.decodeIfPresent(String.self, forKey: .failureSignalMode) ?? "liveOrVisual"
    outputFormat =
      try container.decodeIfPresent(String.self, forKey: .outputFormat) ?? "newlineGitHubURLs"
    autoCopy = try container.decodeIfPresent(Bool.self, forKey: .autoCopy) ?? true
    showSheet = try container.decodeIfPresent(Bool.self, forKey: .showSheet) ?? true
  }
}

public enum TaskBoardPolicyEvidencePredicateValue: String, Codable, CaseIterable, Sendable {
  case isTrue = "is_true"
  case isFalse = "is_false"
  case isZero = "is_zero"
  case isPositive = "is_positive"
  case isPresent = "is_present"
  case isMissing = "is_missing"
}

public struct TaskBoardPolicyEvidencePredicate: Codable, Equatable, Sendable {
  public var predicate: TaskBoardPolicyEvidencePredicateValue

  public init(predicate: TaskBoardPolicyEvidencePredicateValue) {
    self.predicate = predicate
  }
}

public struct TaskBoardPolicyEvidenceCheck: Codable, Equatable, Sendable {
  public var field: TaskBoardPolicyEvidenceField
  public var pass: TaskBoardPolicyEvidencePredicate
  public var failReasonCode: String
  public var missingReasonCode: String

  public init(
    field: TaskBoardPolicyEvidenceField,
    pass: TaskBoardPolicyEvidencePredicate,
    failReasonCode: String,
    missingReasonCode: String
  ) {
    self.field = field
    self.pass = pass
    self.failReasonCode = failReasonCode
    self.missingReasonCode = missingReasonCode
  }
}

public struct TaskBoardPolicySwitchArm: Codable, Equatable, Sendable {
  public var port: String
  public var field: TaskBoardPolicyEvidenceField
  public var predicate: TaskBoardPolicyEvidencePredicate

  public init(
    port: String,
    field: TaskBoardPolicyEvidenceField,
    predicate: TaskBoardPolicyEvidencePredicate
  ) {
    self.port = port
    self.field = field
    self.predicate = predicate
  }
}

public struct TaskBoardPolicyWaitCondition: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    case timer
    case event
  }

  public var kind: Kind
  public var durationSeconds: UInt64?
  public var eventKey: String?

  public init(
    kind: Kind,
    durationSeconds: UInt64? = nil,
    eventKey: String? = nil
  ) {
    self.kind = kind
    self.durationSeconds = durationSeconds
    self.eventKey = eventKey
  }

  public static func timer(_ durationSeconds: UInt64) -> Self {
    Self(kind: .timer, durationSeconds: durationSeconds)
  }

  public static func event(_ eventKey: String) -> Self {
    Self(kind: .event, eventKey: eventKey)
  }
}

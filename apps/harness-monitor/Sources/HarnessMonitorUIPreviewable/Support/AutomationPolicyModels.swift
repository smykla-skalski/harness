import Foundation

public enum AutomationPolicyEventSource: String, CaseIterable, Codable, Identifiable, Sendable {
  case clipboard
  case manualOCRPaste
  case manualReviewTextPaste
  case reviewScreenshotPaste
  case ocrDrop
  case ocrFilePicker
  case screenshotFolder

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .clipboard: "Clipboard"
    case .manualOCRPaste: "Manual Paste"
    case .manualReviewTextPaste: "Review Text Paste"
    case .reviewScreenshotPaste: "Review Screenshot Paste"
    case .ocrDrop: "Drag and Drop"
    case .ocrFilePicker: "File Picker"
    case .screenshotFolder: "Screenshot Folder"
    }
  }

  public var detail: String {
    switch self {
    case .clipboard:
      "Watches NSPasteboard.general change counts while the app is running."
    case .manualOCRPaste:
      "Handles focused Cmd+V and SwiftUI paste destinations."
    case .manualReviewTextPaste:
      "Handles text pasted into Reviews and extracts GitHub pull request links."
    case .reviewScreenshotPaste:
      "Handles screenshots pasted into Reviews and extracts visible pull request rows."
    case .ocrDrop:
      "Handles images dropped onto the Debugging OCR card."
    case .ocrFilePicker:
      "Handles images selected through the file picker."
    case .screenshotFolder:
      "Handles files created in the configured screenshot folder."
    }
  }
}

public enum AutomationClipboardContentKind: String, CaseIterable, Codable, Hashable, Sendable {
  case image
  case text
  case file
  case url
  case unknown

  public var title: String {
    switch self {
    case .image: "Images"
    case .text: "Text"
    case .file: "Files"
    case .url: "URLs"
    case .unknown: "Unknown"
    }
  }
}

public enum AutomationPolicyPreprocessor: String, CaseIterable, Codable, Identifiable, Sendable {
  case respectPasteboardPrivacy
  case skipSensitiveMarkers
  case filterSourceApplications
  case dedupeByFingerprint
  case normalizeGitHubPullRequestLinks
  case dedupePullRequests

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .respectPasteboardPrivacy: "Respect pasteboard privacy"
    case .skipSensitiveMarkers: "Skip concealed/transient content"
    case .filterSourceApplications: "Filter source applications"
    case .dedupeByFingerprint: "Dedupe by fingerprint"
    case .normalizeGitHubPullRequestLinks: "Normalize GitHub PR links"
    case .dedupePullRequests: "Dedupe pull requests"
    }
  }
}

public enum AutomationPolicyAction: String, CaseIterable, Codable, Identifiable, Sendable {
  case ocrImage
  case extractGitHubPullRequests
  case resolveReviewPullRequests
  case copyReviewPullRequestList
  case previewReviewApprovals
  case promptReviewApprovals
  case approveReviewPullRequests
  case runReviewPolicy
  case rememberRecentScan
  case showFeedback
  case openDashboardDebugging
  case recordMetadata

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .ocrImage: "OCR images"
    case .extractGitHubPullRequests: "Extract GitHub PRs"
    case .resolveReviewPullRequests: "Resolve Reviews PRs"
    case .copyReviewPullRequestList: "Copy PR list"
    case .previewReviewApprovals: "Preview review approvals"
    case .promptReviewApprovals: "Prompt before approving"
    case .approveReviewPullRequests: "Approve review PRs"
    case .runReviewPolicy: "Run Reviews policy"
    case .rememberRecentScan: "Remember recent scans"
    case .showFeedback: "Show feedback"
    case .openDashboardDebugging: "Open Debugging"
    case .recordMetadata: "Record metadata"
    }
  }
}

public struct AutomationPolicyOCRConfiguration: Codable, Equatable, Sendable {
  public enum RecognitionLevel: String, Codable, CaseIterable, Sendable {
    case accurate
    case fast
  }

  public var recognitionLevel: RecognitionLevel
  public var automaticallyDetectsLanguage: Bool
  public var usesLanguageCorrection: Bool

  public init(
    recognitionLevel: RecognitionLevel = .accurate,
    automaticallyDetectsLanguage: Bool = true,
    usesLanguageCorrection: Bool = true
  ) {
    self.recognitionLevel = recognitionLevel
    self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
    self.usesLanguageCorrection = usesLanguageCorrection
  }
}

public struct ReviewPullRequestExtractionConfiguration: Codable, Equatable, Sendable {
  public enum RepositoryMode: String, Codable, CaseIterable, Sendable {
    case allConfiguredRepos
    case policyRepositories
    case activeReviewsRepository
  }

  public enum ResultScope: String, Codable, CaseIterable, Sendable {
    case all
    case failing
  }

  public enum FailureSignalMode: String, Codable, CaseIterable, Sendable {
    case liveReviews
    case visualScreenshot
    case liveOrVisual
  }

  public enum OutputFormat: String, Codable, CaseIterable, Sendable {
    case newlineGitHubURLs
    case ownerRepoNumber
    case markdownLinks
  }

  public var repositoryMode: RepositoryMode
  public var policyRepositories: [String]
  public var numberMemoryEnabled: Bool
  public var resultScope: ResultScope
  public var failureSignalMode: FailureSignalMode
  public var outputFormat: OutputFormat
  public var autoCopy: Bool
  public var showSheet: Bool

  public init(
    repositoryMode: RepositoryMode = .allConfiguredRepos,
    policyRepositories: [String] = [],
    numberMemoryEnabled: Bool = true,
    resultScope: ResultScope = .all,
    failureSignalMode: FailureSignalMode = .liveOrVisual,
    outputFormat: OutputFormat = .newlineGitHubURLs,
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
}

public enum AutomationPolicyPostprocessor: String, CaseIterable, Codable, Identifiable, Sendable {
  case sourceSpecificTextCleanup
  case persistResult
  case auditEvent

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .sourceSpecificTextCleanup: "Source-specific text cleanup"
    case .persistResult: "Persist result"
    case .auditEvent: "Audit event"
    }
  }
}

public struct AutomationPolicyMatch: Codable, Equatable, Sendable {
  public var contentKinds: Set<AutomationClipboardContentKind>
  public var sourceAppFilter: AutomationSourceAppFilter

  public init(
    contentKinds: Set<AutomationClipboardContentKind>,
    sourceAppFilter: AutomationSourceAppFilter = AutomationSourceAppFilter()
  ) {
    self.contentKinds = contentKinds
    self.sourceAppFilter = sourceAppFilter
  }
}

public enum AutomationPolicyPayloadKind: String, Codable, Equatable, Sendable {
  case event
  case image
  case text
  case pullRequests
  case unknown

  public var title: String {
    switch self {
    case .event: "event"
    case .image: "image"
    case .text: "text"
    case .pullRequests: "pull requests"
    case .unknown: "unknown"
    }
  }
}

public struct AutomationPolicy: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var eventSource: AutomationPolicyEventSource
  public var isEnabled: Bool
  public var priority: Int
  public var match: AutomationPolicyMatch
  public var preprocessors: [AutomationPolicyPreprocessor]
  public var actions: [AutomationPolicyAction]
  public var dryRun: Bool?
  public var postprocessors: [AutomationPolicyPostprocessor]
  public var ocrConfiguration: AutomationPolicyOCRConfiguration?
  public var reviewPullRequestExtraction: ReviewPullRequestExtractionConfiguration?
  public var executionPlan: AutomationPolicyExecutionPlan?

  public init(
    id: String,
    name: String,
    eventSource: AutomationPolicyEventSource,
    isEnabled: Bool,
    priority: Int,
    match: AutomationPolicyMatch,
    preprocessors: [AutomationPolicyPreprocessor],
    actions: [AutomationPolicyAction],
    dryRun: Bool = false,
    postprocessors: [AutomationPolicyPostprocessor],
    ocrConfiguration: AutomationPolicyOCRConfiguration? = nil,
    reviewPullRequestExtraction: ReviewPullRequestExtractionConfiguration? = nil,
    executionPlan: AutomationPolicyExecutionPlan? = nil
  ) {
    self.id = id
    self.name = name
    self.eventSource = eventSource
    self.isEnabled = isEnabled
    self.priority = priority
    self.match = match
    self.preprocessors = preprocessors
    self.actions = actions
    self.dryRun = dryRun ? true : nil
    self.postprocessors = postprocessors
    self.ocrConfiguration = ocrConfiguration
    self.reviewPullRequestExtraction = reviewPullRequestExtraction
    self.executionPlan = executionPlan
  }

  public var isDryRun: Bool {
    dryRun == true
  }

  public var executionActions: [AutomationPolicyAction] {
    executionPlan?.orderedActions ?? actions
  }

  public func hasAction(_ action: AutomationPolicyAction) -> Bool {
    executionActions.contains(action)
  }

  public func hasPreprocessor(_ preprocessor: AutomationPolicyPreprocessor) -> Bool {
    preprocessors.contains(preprocessor)
  }
}

public struct AutomationPolicyDocument: Codable, Equatable, Sendable {
  public var version: Int
  public var isEnabled: Bool
  public var policies: [AutomationPolicy]
  public var updatedAt: Date

  public init(
    version: Int = 1,
    isEnabled: Bool = true,
    policies: [AutomationPolicy] = Self.defaultPolicies,
    updatedAt: Date = Date()
  ) {
    self.version = version
    self.isEnabled = isEnabled
    self.policies = Self.mergedWithDefaults(policies)
    self.updatedAt = updatedAt
  }

  public func policy(for source: AutomationPolicyEventSource) -> AutomationPolicy {
    policies(for: source).first ?? Self.defaultPolicy(for: source)
  }

  public func policy(id: String) -> AutomationPolicy? {
    Self.mergedWithDefaults(policies).first { $0.id == id }
  }

  public func policies(for source: AutomationPolicyEventSource) -> [AutomationPolicy] {
    Self.mergedWithDefaults(policies)
      .filter { $0.eventSource == source }
      .sorted(by: Self.sortPolicies)
  }

  public func replacingPolicy(_ policy: AutomationPolicy) -> Self {
    var nextPolicies = policies.filter { $0.id != policy.id }
    nextPolicies.append(policy)
    nextPolicies.sort(by: Self.sortPolicies)
    return Self(
      version: version,
      isEnabled: isEnabled,
      policies: nextPolicies,
      updatedAt: Date()
    )
  }

  public func replacingEnabled(_ isEnabled: Bool) -> Self {
    Self(
      version: version,
      isEnabled: isEnabled,
      policies: policies,
      updatedAt: Date()
    )
  }

  public func deletingPolicy(id: String) -> Self {
    guard !Self.defaultPolicyIDs.contains(id) else {
      return self
    }
    return Self(
      version: version,
      isEnabled: isEnabled,
      policies: policies.filter { $0.id != id },
      updatedAt: Date()
    )
  }

  private static func mergedWithDefaults(_ policies: [AutomationPolicy]) -> [AutomationPolicy] {
    var policiesByID = Dictionary(uniqueKeysWithValues: defaultPolicies.map { ($0.id, $0) })
    for policy in policies {
      policiesByID[policy.id] = policy
    }
    return policiesByID.values.sorted(by: sortPolicies)
  }

  private static func sortPolicies(_ lhs: AutomationPolicy, _ rhs: AutomationPolicy) -> Bool {
    if lhs.priority == rhs.priority {
      return lhs.id < rhs.id
    }
    return lhs.priority < rhs.priority
  }
}

import Foundation

public enum AutomationPolicyEventSource: String, CaseIterable, Codable, Identifiable, Sendable {
  case clipboard
  case manualOCRPaste
  case manualReviewTextPaste
  case ocrDrop
  case ocrFilePicker
  case screenshotFolder

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .clipboard: "Clipboard"
    case .manualOCRPaste: "Manual Paste"
    case .manualReviewTextPaste: "Review Text Paste"
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
    postprocessors: [AutomationPolicyPostprocessor]
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
  }

  public var isDryRun: Bool {
    dryRun == true
  }

  public func hasAction(_ action: AutomationPolicyAction) -> Bool {
    actions.contains(action)
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

  public static var defaultPolicyIDs: Set<String> {
    Set(defaultPolicies.map(\.id))
  }

  public static let defaultPolicies: [AutomationPolicy] = [
    AutomationPolicy(
      id: "clipboard.image-ocr",
      name: "Clipboard Image OCR",
      eventSource: .clipboard,
      isEnabled: false,
      priority: 10,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [
        .respectPasteboardPrivacy,
        .skipSensitiveMarkers,
        .filterSourceApplications,
        .dedupeByFingerprint,
      ],
      actions: [.ocrImage, .rememberRecentScan, .showFeedback, .recordMetadata],
      postprocessors: [.sourceSpecificTextCleanup, .persistResult, .auditEvent]
    ),
    AutomationPolicy(
      id: "clipboard.metadata",
      name: "Clipboard Metadata",
      eventSource: .clipboard,
      isEnabled: false,
      priority: 12,
      match: AutomationPolicyMatch(contentKinds: [.text, .file, .url, .unknown]),
      preprocessors: [
        .respectPasteboardPrivacy,
        .skipSensitiveMarkers,
        .filterSourceApplications,
      ],
      actions: [.recordMetadata],
      postprocessors: [.auditEvent]
    ),
    userOriginatedOCRPolicy(
      id: "ocr.manual-paste",
      name: "Manual OCR Paste",
      eventSource: .manualOCRPaste,
      priority: 20,
      actions: [.ocrImage, .rememberRecentScan, .showFeedback, .recordMetadata]
    ),
    AutomationPolicy(
      id: "reviews.text-paste",
      name: "Review Text Paste",
      eventSource: .manualReviewTextPaste,
      isEnabled: true,
      priority: 22,
      match: AutomationPolicyMatch(contentKinds: [.text, .url]),
      preprocessors: [.normalizeGitHubPullRequestLinks, .dedupePullRequests],
      actions: [
        .extractGitHubPullRequests,
        .previewReviewApprovals,
        .promptReviewApprovals,
        .recordMetadata,
      ],
      postprocessors: [.auditEvent]
    ),
    userOriginatedOCRPolicy(
      id: "ocr.drop",
      name: "Drag and Drop OCR",
      eventSource: .ocrDrop,
      priority: 30
    ),
    userOriginatedOCRPolicy(
      id: "ocr.file-picker",
      name: "File Picker OCR",
      eventSource: .ocrFilePicker,
      priority: 40
    ),
    userOriginatedOCRPolicy(
      id: "ocr.screenshot-folder",
      name: "Screenshot Folder OCR",
      eventSource: .screenshotFolder,
      priority: 50
    ),
  ]

  public static func defaultPolicy(for source: AutomationPolicyEventSource) -> AutomationPolicy {
    defaultPolicies.first { $0.eventSource == source }
      ?? userOriginatedOCRPolicy(
        id: "policy.\(source.rawValue)",
        name: source.title,
        eventSource: source,
        priority: 1_000
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

  private static func userOriginatedOCRPolicy(
    id: String,
    name: String,
    eventSource: AutomationPolicyEventSource,
    priority: Int,
    actions: [AutomationPolicyAction] = [.ocrImage, .rememberRecentScan, .recordMetadata]
  ) -> AutomationPolicy {
    AutomationPolicy(
      id: id,
      name: name,
      eventSource: eventSource,
      isEnabled: true,
      priority: priority,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [.dedupeByFingerprint],
      actions: actions,
      postprocessors: [.sourceSpecificTextCleanup, .persistResult, .auditEvent]
    )
  }
}

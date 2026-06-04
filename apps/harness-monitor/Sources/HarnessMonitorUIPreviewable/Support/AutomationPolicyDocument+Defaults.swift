import Foundation

extension AutomationPolicyDocument {
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
    if let defaultPolicy = defaultPolicies.first(where: { $0.eventSource == source }) {
      return defaultPolicy
    }
    switch source {
    case .manualReviewTextPaste:
      return reviewTextPasteFallbackPolicy()
    case .reviewScreenshotPaste:
      return reviewScreenshotPasteFallbackPolicy()
    case .manualOCRPaste:
      return userOriginatedOCRPolicy(
        id: "policy.\(source.rawValue)",
        name: source.title,
        eventSource: source,
        priority: 1_000,
        isEnabled: false
      )
    case .clipboard, .ocrDrop, .ocrFilePicker, .screenshotFolder:
      return userOriginatedOCRPolicy(
        id: "policy.\(source.rawValue)",
        name: source.title,
        eventSource: source,
        priority: 1_000
      )
    }
  }

  private static func userOriginatedOCRPolicy(
    id: String,
    name: String,
    eventSource: AutomationPolicyEventSource,
    priority: Int,
    isEnabled: Bool = true,
    actions: [AutomationPolicyAction] = [.ocrImage, .rememberRecentScan, .recordMetadata]
  ) -> AutomationPolicy {
    AutomationPolicy(
      id: id,
      name: name,
      eventSource: eventSource,
      isEnabled: isEnabled,
      priority: priority,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [.dedupeByFingerprint],
      actions: actions,
      postprocessors: [.sourceSpecificTextCleanup, .persistResult, .auditEvent]
    )
  }

  private static func reviewTextPasteFallbackPolicy() -> AutomationPolicy {
    AutomationPolicy(
      id: "policy.manualReviewTextPaste",
      name: "Review Text Paste",
      eventSource: .manualReviewTextPaste,
      isEnabled: false,
      priority: 1_000,
      match: AutomationPolicyMatch(contentKinds: [.text, .url]),
      preprocessors: [.normalizeGitHubPullRequestLinks, .dedupePullRequests],
      actions: [
        .extractGitHubPullRequests,
        .previewReviewApprovals,
        .promptReviewApprovals,
        .recordMetadata,
      ],
      postprocessors: [.auditEvent]
    )
  }

  private static func reviewScreenshotPasteFallbackPolicy() -> AutomationPolicy {
    AutomationPolicy(
      id: "policy.reviewScreenshotPaste",
      name: "Review Screenshot Paste",
      eventSource: .reviewScreenshotPaste,
      isEnabled: false,
      priority: 1_000,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [.dedupeByFingerprint, .normalizeGitHubPullRequestLinks, .dedupePullRequests],
      actions: [
        .ocrImage,
        .extractGitHubPullRequests,
        .resolveReviewPullRequests,
        .copyExtractedGitHubPullRequestURLs,
        .copyReviewPullRequestList,
        .previewReviewApprovals,
        .recordMetadata,
      ],
      postprocessors: [.auditEvent],
      ocrConfiguration: AutomationPolicyOCRConfiguration(),
      reviewPullRequestExtraction: ReviewPullRequestExtractionConfiguration()
    )
  }
}

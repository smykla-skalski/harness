import HarnessMonitorPolicyCanvas

private let automationPolicyActionToCanvasAction:
  [AutomationPolicyAction: HarnessMonitorPolicyCanvas.AutomationPolicyAction] = [
    .ocrImage: .ocrImage,
    .extractGitHubPullRequests: .extractGitHubPullRequests,
    .resolveReviewPullRequests: .resolveReviewPullRequests,
    .copyExtractedGitHubPullRequestURLs: .copyExtractedGitHubPullRequestURLs,
    .copyReviewPullRequestList: .copyReviewPullRequestList,
    .previewReviewApprovals: .previewReviewApprovals,
    .promptReviewApprovals: .promptReviewApprovals,
    .approveReviewPullRequests: .approveReviewPullRequests,
    .runReviewPolicy: .runReviewPolicy,
    .showActivityToast: .showActivityToast,
    .updateActivityToast: .updateActivityToast,
    .hideActivityToast: .hideActivityToast,
    .rememberRecentScan: .rememberRecentScan,
    .showFeedback: .showFeedback,
    .openDashboardDebugging: .openDashboardDebugging,
    .recordMetadata: .recordMetadata,
  ]

private let canvasActionToAutomationPolicyAction:
  [HarnessMonitorPolicyCanvas.AutomationPolicyAction: AutomationPolicyAction] = [
    .ocrImage: .ocrImage,
    .extractGitHubPullRequests: .extractGitHubPullRequests,
    .resolveReviewPullRequests: .resolveReviewPullRequests,
    .copyExtractedGitHubPullRequestURLs: .copyExtractedGitHubPullRequestURLs,
    .copyReviewPullRequestList: .copyReviewPullRequestList,
    .previewReviewApprovals: .previewReviewApprovals,
    .promptReviewApprovals: .promptReviewApprovals,
    .approveReviewPullRequests: .approveReviewPullRequests,
    .runReviewPolicy: .runReviewPolicy,
    .showActivityToast: .showActivityToast,
    .updateActivityToast: .updateActivityToast,
    .hideActivityToast: .hideActivityToast,
    .rememberRecentScan: .rememberRecentScan,
    .showFeedback: .showFeedback,
    .openDashboardDebugging: .openDashboardDebugging,
    .recordMetadata: .recordMetadata,
  ]

@MainActor
extension PolicyCanvasAutomationStore {
  static func automationCenterBridge(
    center: AutomationPolicyCenter = .shared
  ) -> PolicyCanvasAutomationStore {
    PolicyCanvasAutomationStore(
      state: .bridgeState(center),
      setAutomationEnabled: { isEnabled in
        center.setAutomationEnabled(isEnabled)
        return .bridgeState(center)
      },
      replaceCanvasPolicies: { policies in
        center.replaceCanvasPolicies(policies.map(AutomationPolicy.init))
        return .bridgeState(center)
      }
    )
  }
}

@MainActor
extension PolicyCanvasAutomationStoreState {
  fileprivate static func bridgeState(_ center: AutomationPolicyCenter) -> Self {
    PolicyCanvasAutomationStoreState(
      document: HarnessMonitorPolicyCanvas.AutomationPolicyDocument(center.document),
      clipboardRuntimeState: HarnessMonitorPolicyCanvas.ClipboardAutomationRuntimeState(
        center.clipboardRuntimeState
      ),
      lastClipboardEventSummary: center.lastClipboardEventSummary,
      lastClipboardEventAt: center.lastClipboardEventAt,
      recentAutomationEvents: center.recentAutomationEvents.map(
        HarnessMonitorPolicyCanvas.AutomationPolicyEventRecord.init
      )
    )
  }
}

extension HarnessMonitorPolicyCanvas.ClipboardAutomationRuntimeState {
  init(_ state: ClipboardAutomationRuntimeState) {
    switch state {
    case .off:
      self = .off
    case .watching:
      self = .watching
    case .paused(let reason):
      self = .paused(reason)
    case .denied:
      self = .denied
    case .skipped(let reason):
      self = .skipped(reason)
    case .matched(let policy):
      self = .matched(policy)
    case .failed(let message):
      self = .failed(message)
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyEventSource {
  init(_ source: AutomationPolicyEventSource) {
    switch source {
    case .clipboard:
      self = .clipboard
    case .manualOCRPaste:
      self = .manualOCRPaste
    case .manualReviewTextPaste:
      self = .manualReviewTextPaste
    case .reviewScreenshotPaste:
      self = .reviewScreenshotPaste
    case .ocrDrop:
      self = .ocrDrop
    case .ocrFilePicker:
      self = .ocrFilePicker
    case .screenshotFolder:
      self = .screenshotFolder
    }
  }
}

extension AutomationPolicyEventSource {
  init(_ source: HarnessMonitorPolicyCanvas.AutomationPolicyEventSource) {
    switch source {
    case .clipboard:
      self = .clipboard
    case .manualOCRPaste:
      self = .manualOCRPaste
    case .manualReviewTextPaste:
      self = .manualReviewTextPaste
    case .reviewScreenshotPaste:
      self = .reviewScreenshotPaste
    case .ocrDrop:
      self = .ocrDrop
    case .ocrFilePicker:
      self = .ocrFilePicker
    case .screenshotFolder:
      self = .screenshotFolder
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationClipboardContentKind {
  init(_ kind: AutomationClipboardContentKind) {
    switch kind {
    case .image:
      self = .image
    case .text:
      self = .text
    case .file:
      self = .file
    case .url:
      self = .url
    case .unknown:
      self = .unknown
    }
  }
}

extension AutomationClipboardContentKind {
  init(_ kind: HarnessMonitorPolicyCanvas.AutomationClipboardContentKind) {
    switch kind {
    case .image:
      self = .image
    case .text:
      self = .text
    case .file:
      self = .file
    case .url:
      self = .url
    case .unknown:
      self = .unknown
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyPreprocessor {
  init(_ preprocessor: AutomationPolicyPreprocessor) {
    switch preprocessor {
    case .respectPasteboardPrivacy:
      self = .respectPasteboardPrivacy
    case .skipSensitiveMarkers:
      self = .skipSensitiveMarkers
    case .filterSourceApplications:
      self = .filterSourceApplications
    case .dedupeByFingerprint:
      self = .dedupeByFingerprint
    case .normalizeGitHubPullRequestLinks:
      self = .normalizeGitHubPullRequestLinks
    case .dedupePullRequests:
      self = .dedupePullRequests
    }
  }
}

extension AutomationPolicyPreprocessor {
  init(_ preprocessor: HarnessMonitorPolicyCanvas.AutomationPolicyPreprocessor) {
    switch preprocessor {
    case .respectPasteboardPrivacy:
      self = .respectPasteboardPrivacy
    case .skipSensitiveMarkers:
      self = .skipSensitiveMarkers
    case .filterSourceApplications:
      self = .filterSourceApplications
    case .dedupeByFingerprint:
      self = .dedupeByFingerprint
    case .normalizeGitHubPullRequestLinks:
      self = .normalizeGitHubPullRequestLinks
    case .dedupePullRequests:
      self = .dedupePullRequests
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyAction {
  init(_ action: AutomationPolicyAction) {
    guard let mapped = automationPolicyActionToCanvasAction[action] else {
      preconditionFailure("Unsupported automation policy action: \(action)")
    }
    self = mapped
  }
}

extension AutomationPolicyAction {
  init(_ action: HarnessMonitorPolicyCanvas.AutomationPolicyAction) {
    guard let mapped = canvasActionToAutomationPolicyAction[action] else {
      preconditionFailure("Unsupported canvas automation action: \(action)")
    }
    self = mapped
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyPostprocessor {
  init(_ postprocessor: AutomationPolicyPostprocessor) {
    switch postprocessor {
    case .sourceSpecificTextCleanup:
      self = .sourceSpecificTextCleanup
    case .persistResult:
      self = .persistResult
    case .auditEvent:
      self = .auditEvent
    }
  }
}

extension AutomationPolicyPostprocessor {
  init(_ postprocessor: HarnessMonitorPolicyCanvas.AutomationPolicyPostprocessor) {
    switch postprocessor {
    case .sourceSpecificTextCleanup:
      self = .sourceSpecificTextCleanup
    case .persistResult:
      self = .persistResult
    case .auditEvent:
      self = .auditEvent
    }
  }
}

extension HarnessMonitorPolicyCanvas.AutomationPolicyPayloadKind {
  init(_ kind: AutomationPolicyPayloadKind) {
    switch kind {
    case .event:
      self = .event
    case .image:
      self = .image
    case .text:
      self = .text
    case .pullRequests:
      self = .pullRequests
    case .unknown:
      self = .unknown
    }
  }
}

extension AutomationPolicyPayloadKind {
  init(_ kind: HarnessMonitorPolicyCanvas.AutomationPolicyPayloadKind) {
    switch kind {
    case .event:
      self = .event
    case .image:
      self = .image
    case .text:
      self = .text
    case .pullRequests:
      self = .pullRequests
    case .unknown:
      self = .unknown
    }
  }
}

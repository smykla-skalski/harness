import HarnessMonitorKit

// Display copy for the policy library palette. Titles use sentence case so the
// palette reads like the rest of the app (sentence-case nav, sentence-case node
// labels); only established acronyms (OCR, URL) stay capitalized. Subtitles are
// the friendly one-line descriptions, distinct from the technical `subtitle`
// strings used by the inspector. `PolicyCanvasLibraryCopyTests` locks the
// sentence-case contract.

extension PolicyCanvasAutomationPaletteItem {
  var libraryTitle: String {
    switch self {
    case .clipboardMonitor:
      "Clipboard monitor"
    case .focusedPaste:
      "Focused paste"
    case .reviewTextPaste:
      "Review text paste"
    case .dragDropOCR:
      "Dropped images"
    case .filePickerOCR:
      "Selected files"
    case .screenshotFolder:
      "Screenshot folder"
    case .contentImages:
      "Images"
    case .contentText:
      "Text"
    case .contentFiles:
      "Files"
    case .contentURLs:
      "URLs"
    case .pasteboardPrivacy:
      "Pasteboard privacy"
    case .skipSensitiveMarkers:
      "Skip sensitive content"
    case .sourceApplicationFilter:
      "Source app filter"
    case .dedupeFingerprint:
      "Deduplication"
    case .normalizeGitHubPRLinks:
      "Normalize PR links"
    case .dedupePullRequests:
      "Dedupe PRs"
    case .ocrImages:
      "OCR images"
    case .extractGitHubPullRequests:
      "Extract PRs"
    case .previewReviewApprovals:
      "Preview approvals"
    case .promptReviewApprovals:
      "Prompt approvals"
    case .approveReviewPullRequests:
      "Approve PRs"
    case .runReviewPolicy:
      "Run Reviews policy"
    case .rememberRecentScans:
      "Remember recent scans"
    case .showFeedback:
      "Show feedback"
    case .openDebugging:
      "Open debugging"
    case .recordMetadata:
      "Record metadata"
    case .sourceSpecificCleanup:
      "Text cleanup"
    case .persistResult:
      "Persist OCR"
    case .auditEvent:
      "Audit event"
    }
  }

  var librarySubtitle: String {
    switch self {
    case .clipboardMonitor:
      "Pasteboard polling"
    case .focusedPaste:
      "Focused paste events"
    case .reviewTextPaste:
      "GitHub PR links"
    case .dragDropOCR:
      "OCR on dropped images"
    case .filePickerOCR:
      "OCR on selected images"
    case .screenshotFolder:
      "Screenshot files"
    case .contentImages:
      "Screenshots and images"
    case .contentText:
      "Copied text"
    case .contentFiles:
      "File URLs"
    case .contentURLs:
      "Copied links"
    case .pasteboardPrivacy:
      "Pasteboard privacy"
    case .skipSensitiveMarkers:
      "Transient content"
    case .sourceApplicationFilter:
      "Source app allowlist"
    case .dedupeFingerprint:
      "Duplicate scans"
    case .normalizeGitHubPRLinks:
      "Copied PR URLs"
    case .dedupePullRequests:
      "Duplicate PR links"
    case .ocrImages:
      "OCR recognition"
    case .extractGitHubPullRequests:
      "Pull request links"
    case .previewReviewApprovals:
      "Approval cards"
    case .promptReviewApprovals:
      "Approval prompt"
    case .approveReviewPullRequests:
      "Eligible PR approvals"
    case .runReviewPolicy:
      "Reviews workflow"
    case .rememberRecentScans:
      "Recent scan storage"
    case .showFeedback:
      "Visual feedback"
    case .openDebugging:
      "Debugging route"
    case .recordMetadata:
      "Source metadata"
    case .sourceSpecificCleanup:
      "Recognized text"
    case .persistResult:
      "OCR text persistence"
    case .auditEvent:
      "Policy event log"
    }
  }
}

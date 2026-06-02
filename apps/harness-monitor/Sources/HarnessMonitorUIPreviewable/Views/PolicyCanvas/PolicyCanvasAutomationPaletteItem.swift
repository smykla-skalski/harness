import HarnessMonitorKit
import SwiftUI

enum PolicyCanvasAutomationPaletteSection: String, CaseIterable, Identifiable {
  case sources
  case content
  case safety
  case actions
  case results

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sources: "Sources"
    case .content: "Content"
    case .safety: "Safety"
    case .actions: "Actions"
    case .results: "Results"
    }
  }
}

enum PolicyCanvasAutomationPaletteItem: String, CaseIterable, Identifiable {
  case clipboardMonitor
  case focusedPaste
  case reviewTextPaste
  case reviewScreenshotPaste
  case dragDropOCR
  case filePickerOCR
  case screenshotFolder
  case contentImages
  case contentText
  case contentFiles
  case contentURLs
  case pasteboardPrivacy
  case skipSensitiveMarkers
  case sourceApplicationFilter
  case dedupeFingerprint
  case normalizeGitHubPRLinks
  case dedupePullRequests
  case ocrImages
  case extractGitHubPullRequests
  case resolveReviewPullRequests
  case copyReviewPullRequestList
  case previewReviewApprovals
  case promptReviewApprovals
  case approveReviewPullRequests
  case runReviewPolicy
  case rememberRecentScans
  case showFeedback
  case openDebugging
  case recordMetadata
  case sourceSpecificCleanup
  case persistResult
  case auditEvent

  var id: String { rawValue }

  var section: PolicyCanvasAutomationPaletteSection {
    switch self {
    case .clipboardMonitor, .focusedPaste, .reviewTextPaste, .reviewScreenshotPaste,
      .dragDropOCR, .filePickerOCR, .screenshotFolder:
      .sources
    case .contentImages, .contentText, .contentFiles, .contentURLs:
      .content
    case .pasteboardPrivacy, .skipSensitiveMarkers, .sourceApplicationFilter, .dedupeFingerprint,
      .normalizeGitHubPRLinks, .dedupePullRequests:
      .safety
    case .ocrImages, .extractGitHubPullRequests, .resolveReviewPullRequests,
      .copyReviewPullRequestList, .previewReviewApprovals, .promptReviewApprovals,
      .approveReviewPullRequests, .runReviewPolicy, .rememberRecentScans, .showFeedback,
      .openDebugging, .recordMetadata:
      .actions
    case .sourceSpecificCleanup, .persistResult, .auditEvent:
      .results
    }
  }

  var title: String {
    switch self {
    case .clipboardMonitor: "Clipboard Monitor"
    case .focusedPaste: "Focused Paste"
    case .reviewTextPaste: "Review Text Paste"
    case .reviewScreenshotPaste: "Review Screenshot Paste"
    case .dragDropOCR: "Drag and Drop OCR"
    case .filePickerOCR: "File Picker OCR"
    case .screenshotFolder: "Screenshot Folder"
    case .contentImages: "Images"
    case .contentText: "Text"
    case .contentFiles: "Files"
    case .contentURLs: "URLs"
    case .pasteboardPrivacy: "Pasteboard Privacy"
    case .skipSensitiveMarkers: "Skip Sensitive Content"
    case .sourceApplicationFilter: "Source App Filter"
    case .dedupeFingerprint: "Dedupe Fingerprint"
    case .normalizeGitHubPRLinks: "Normalize GitHub PR Links"
    case .dedupePullRequests: "Dedupe Pull Requests"
    case .ocrImages: "OCR Images"
    case .extractGitHubPullRequests: "Extract GitHub PRs"
    case .resolveReviewPullRequests: "Resolve Reviews PRs"
    case .copyReviewPullRequestList: "Copy PR List"
    case .previewReviewApprovals: "Preview Review Approvals"
    case .promptReviewApprovals: "Prompt Review Approvals"
    case .approveReviewPullRequests: "Approve Review PRs"
    case .runReviewPolicy: "Run Reviews Policy"
    case .rememberRecentScans: "Remember Recent Scans"
    case .showFeedback: "Show Feedback"
    case .openDebugging: "Open Debugging"
    case .recordMetadata: "Record Metadata"
    case .sourceSpecificCleanup: "Source Text Cleanup"
    case .persistResult: "Persist OCR Result"
    case .auditEvent: "Audit Event"
    }
  }

  var subtitle: String {
    switch self {
    case .clipboardMonitor: "NSPasteboard.general polling"
    case .focusedPaste: "Cmd-V and SwiftUI paste"
    case .reviewTextPaste: "GitHub PR links from text"
    case .reviewScreenshotPaste: "GitHub PR rows from screenshots"
    case .dragDropOCR: "Images dropped into OCR"
    case .filePickerOCR: "Images chosen by picker"
    case .screenshotFolder: "System screenshot files"
    case .contentImages: "Match screenshots and images"
    case .contentText: "Match copied text"
    case .contentFiles: "Match file URLs"
    case .contentURLs: "Match copied links"
    case .pasteboardPrivacy: "Respect pasteboard privacy"
    case .skipSensitiveMarkers: "Skip transient content"
    case .sourceApplicationFilter: "Allow or deny source apps"
    case .dedupeFingerprint: "Prevent duplicate scans"
    case .normalizeGitHubPRLinks: "Clean copied PR URLs"
    case .dedupePullRequests: "Collapse duplicate PRs"
    case .ocrImages: "Run OCR recognition"
    case .extractGitHubPullRequests: "Find PR links in text"
    case .resolveReviewPullRequests: "Match extracted PRs to Reviews"
    case .copyReviewPullRequestList: "Copy resolved PR output"
    case .previewReviewApprovals: "Show PR detail cards"
    case .promptReviewApprovals: "Ask before approving"
    case .approveReviewPullRequests: "Approve eligible PRs"
    case .runReviewPolicy: "Start Reviews workflow"
    case .rememberRecentScans: "Store in Recent"
    case .showFeedback: "Show visual feedback"
    case .openDebugging: "Route to Debugging OCR"
    case .recordMetadata: "Keep source metadata"
    case .sourceSpecificCleanup: "Clean recognized text"
    case .persistResult: "Persist OCR text"
    case .auditEvent: "Write policy event"
    }
  }

  var symbolName: String {
    switch self {
    case .clipboardMonitor: "doc.on.clipboard"
    case .focusedPaste: "command"
    case .reviewTextPaste: "link.badge.plus"
    case .reviewScreenshotPaste: "camera.viewfinder"
    case .dragDropOCR: "square.and.arrow.down"
    case .filePickerOCR: "folder"
    case .screenshotFolder: "camera.viewfinder"
    case .contentImages: "photo"
    case .contentText: "text.alignleft"
    case .contentFiles: "doc"
    case .contentURLs: "link"
    case .pasteboardPrivacy: "hand.raised"
    case .skipSensitiveMarkers: "eye.slash"
    case .sourceApplicationFilter: "app.badge"
    case .dedupeFingerprint: "number.square"
    case .normalizeGitHubPRLinks: "wand.and.stars"
    case .dedupePullRequests: "square.stack.3d.down.right"
    case .ocrImages: "text.viewfinder"
    case .extractGitHubPullRequests: "link"
    case .resolveReviewPullRequests: "doc.text.magnifyingglass"
    case .copyReviewPullRequestList: "doc.on.clipboard"
    case .previewReviewApprovals: "rectangle.stack.badge.person.crop"
    case .promptReviewApprovals: "questionmark.bubble"
    case .approveReviewPullRequests: "checkmark.seal"
    case .runReviewPolicy: "bolt"
    case .rememberRecentScans: "clock.arrow.circlepath"
    case .showFeedback: "sparkles"
    case .openDebugging: "wrench.and.screwdriver"
    case .recordMetadata: "tag"
    case .sourceSpecificCleanup: "wand.and.stars"
    case .persistResult: "externaldrive"
    case .auditEvent: "list.bullet.clipboard"
    }
  }

  var nodeKind: PolicyCanvasNodeKind {
    switch self {
    case .reviewScreenshotPaste:
      return .reviewScreenshotPaste
    case .ocrImages:
      return .ocrImage
    case .resolveReviewPullRequests:
      return .resolveReviewPullRequests
    case .copyReviewPullRequestList:
      return .copyReviewPullRequestList
    default:
      break
    }
    switch section {
    case .sources:
      return .trigger
    case .content, .safety:
      return .ifThenElse
    case .actions:
      return .actionStep
    case .results:
      return .handoff
    }
  }

  var automationBinding: TaskBoardPolicyPipelineAutomationBinding {
    switch self {
    case .clipboardMonitor:
      .canvasDefault(source: .clipboard)
    case .focusedPaste:
      .canvasDefault(source: .manualOCRPaste)
    case .reviewTextPaste:
      .canvasDefault(source: .manualReviewTextPaste)
    case .reviewScreenshotPaste:
      .canvasDefault(source: .reviewScreenshotPaste)
    case .dragDropOCR:
      .canvasDefault(source: .ocrDrop)
    case .filePickerOCR:
      .canvasDefault(source: .ocrFilePicker)
    case .screenshotFolder:
      .canvasDefault(source: .screenshotFolder)
    case .contentImages:
      .canvasComponent(contentKinds: [.image])
    case .contentText:
      .canvasComponent(contentKinds: [.text])
    case .contentFiles:
      .canvasComponent(contentKinds: [.file])
    case .contentURLs:
      .canvasComponent(contentKinds: [.url])
    case .pasteboardPrivacy:
      .canvasComponent(preprocessors: [.respectPasteboardPrivacy])
    case .skipSensitiveMarkers:
      .canvasComponent(preprocessors: [.skipSensitiveMarkers])
    case .sourceApplicationFilter:
      .canvasComponent(preprocessors: [.filterSourceApplications])
    case .dedupeFingerprint:
      .canvasComponent(preprocessors: [.dedupeByFingerprint])
    case .normalizeGitHubPRLinks:
      .canvasComponent(preprocessors: [.normalizeGitHubPullRequestLinks])
    case .dedupePullRequests:
      .canvasComponent(preprocessors: [.dedupePullRequests])
    case .ocrImages:
      .canvasComponent(actions: [.ocrImage])
    case .extractGitHubPullRequests:
      .canvasComponent(actions: [.extractGitHubPullRequests])
    case .resolveReviewPullRequests:
      .canvasComponent(actions: [.resolveReviewPullRequests])
    case .copyReviewPullRequestList:
      .canvasComponent(actions: [.copyReviewPullRequestList])
    case .previewReviewApprovals:
      .canvasComponent(actions: [.previewReviewApprovals])
    case .promptReviewApprovals:
      .canvasComponent(actions: [.promptReviewApprovals])
    case .approveReviewPullRequests:
      .canvasComponent(actions: [.approveReviewPullRequests])
    case .runReviewPolicy:
      .canvasComponent(actions: [.runReviewPolicy])
    case .rememberRecentScans:
      .canvasComponent(actions: [.rememberRecentScan])
    case .showFeedback:
      .canvasComponent(actions: [.showFeedback])
    case .openDebugging:
      .canvasComponent(actions: [.openDashboardDebugging])
    case .recordMetadata:
      .canvasComponent(actions: [.recordMetadata])
    case .sourceSpecificCleanup:
      .canvasComponent(postprocessors: [.sourceSpecificTextCleanup])
    case .persistResult:
      .canvasComponent(postprocessors: [.persistResult])
    case .auditEvent:
      .canvasComponent(postprocessors: [.auditEvent])
    }
  }

  static func items(in section: PolicyCanvasAutomationPaletteSection) -> [Self] {
    allCases.filter { $0.section == section }
  }
}

import Foundation
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasAutomationPolicyCompiler {
  static func eventSource(for node: PolicyCanvasNode) -> AutomationPolicyEventSource? {
    if node.kind == .reviewScreenshotPaste {
      return .reviewScreenshotPaste
    }
    guard node.kind == .source else {
      return nil
    }
    let text = normalizedText(nodeText(node))
    if containsAny(text, ["screenshot folder", "screenshots folder", "screenshot monitor"]) {
      return .screenshotFolder
    }
    if containsAny(text, ["file picker", "choose images", "choose image", "open panel"]) {
      return .ocrFilePicker
    }
    if containsAny(text, ["drag and drop", "drop images", "dropped image", "drop zone"]) {
      return .ocrDrop
    }
    if containsAny(
      text,
      [
        "review screenshot paste",
        "pr screenshot",
        "pull request screenshot",
        "screenshot pr",
      ])
    {
      return .reviewScreenshotPaste
    }
    if containsAny(
      text,
      [
        "review text paste",
        "paste prs",
        "paste pull requests",
        "github pull request",
        "github pr",
      ])
    {
      return .manualReviewTextPaste
    }
    if containsAny(text, ["manual paste", "focused paste", "command v", "cmd v"]) {
      return .manualOCRPaste
    }
    if containsAny(text, ["clipboard", "pasteboard"]) {
      return .clipboard
    }
    guard containsAny(text, ["paste"]) else {
      return nil
    }
    return .manualOCRPaste
  }

  static func sourceAppFilter(from text: String) -> AutomationSourceAppFilter {
    let identifiers = bundleIdentifiers(from: text)
    guard !identifiers.isEmpty else {
      return AutomationSourceAppFilter()
    }
    if containsAny(text, ["allow only", "allowed apps", "allowlist", "source apps only"]) {
      return AutomationSourceAppFilter(
        mode: .allowedOnly,
        allowedBundleIdentifiers: identifiers
      )
    }
    return AutomationSourceAppFilter(deniedBundleIdentifiers: identifiers)
  }

  static func bundleIdentifiers(from text: String) -> [String] {
    text
      .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
      .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
      .filter { $0.hasPrefix("com.") && $0.contains(".") }
  }

  static func nodeText(_ node: PolicyCanvasNode) -> String {
    var text = String()
    text.reserveCapacity(96)
    appendNodeText(node, to: &text)
    return text
  }

  static func appendNodeText(_ node: PolicyCanvasNode, to text: inout String) {
    appendGraphToken(node.id, to: &text)
    appendGraphToken(node.title, to: &text)
    appendGraphToken(node.subtitle, to: &text)
    appendGraphToken(node.kind.title, to: &text)
    if let policyKind = node.policyKind {
      appendGraphToken(policyKind.discriminator, to: &text)
      if let workflow = policyKind.workflow {
        appendGraphToken(workflow, to: &text)
      }
      if let reasonCode = policyKind.reasonCode {
        appendGraphToken(reasonCode, to: &text)
      }
      for reasonCode in policyKind.reasonCodes {
        appendGraphToken(reasonCode.rawValue, to: &text)
      }
    }
  }

  static func appendGraphToken(_ token: String, to text: inout String) {
    guard !token.isEmpty else { return }
    if !text.isEmpty {
      text.append(" ")
    }
    text.append(token)
  }

  static func normalizedText(_ text: String) -> String {
    text
      .lowercased()
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "+", with: " ")
  }

  static func containsAny(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0) }
  }

  static func containsWord(_ text: String, _ words: [String]) -> Bool {
    let paddedText = " \(text) "
    return words.contains { word in
      paddedText.contains(" \(word) ")
    }
  }

  static func graphText(
    reachableNodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge]
  ) -> String {
    var reachableIDs = Set<String>()
    reachableIDs.reserveCapacity(reachableNodes.count)
    for node in reachableNodes {
      reachableIDs.insert(node.id)
    }

    var text = String()
    text.reserveCapacity(reachableNodes.count * 96 + edges.count * 48)
    for node in reachableNodes {
      appendNodeText(node, to: &text)
    }
    for edge in edges
    where reachableIDs.contains(edge.source.nodeID)
      && reachableIDs.contains(edge.target.nodeID)
    {
      appendGraphToken(edge.label, to: &text)
      appendGraphToken(edge.condition, to: &text)
      appendGraphToken(edge.source.portID, to: &text)
      appendGraphToken(edge.target.portID, to: &text)
    }
    return normalizedText(text)
  }

  static func contentKinds(from text: String) -> Set<AutomationClipboardContentKind> {
    var kinds: Set<AutomationClipboardContentKind> = []
    if containsWord(text, ["image", "images", "screenshot", "screenshots", "ocr", "scan"]) {
      kinds.insert(.image)
    }
    if containsWord(text, ["text", "copy", "message", "messages", "string"]) {
      kinds.insert(.text)
    }
    if containsWord(text, ["file", "files", "path", "paths", "document"]) {
      kinds.insert(.file)
    }
    if containsWord(text, ["url", "urls", "link", "links", "web", "github", "pr", "prs"]) {
      kinds.insert(.url)
    }
    if containsAny(text, ["pull request", "pull requests"]) {
      kinds.formUnion([.text, .url])
    }
    if containsWord(text, ["unknown", "fallback"]) || containsAny(text, ["any content"]) {
      kinds.insert(.unknown)
    }
    return kinds.isEmpty ? [.image] : kinds
  }

  static func preprocessors(
    for source: AutomationPolicyEventSource,
    contentKinds: Set<AutomationClipboardContentKind>,
    text: String
  ) -> [AutomationPolicyPreprocessor] {
    var preprocessors: Set<AutomationPolicyPreprocessor> = []
    if source == .clipboard || containsAny(text, ["privacy", "pasteboard"]) {
      preprocessors.insert(.respectPasteboardPrivacy)
    }
    if source == .clipboard || containsAny(text, ["sensitive", "concealed", "transient"]) {
      preprocessors.insert(.skipSensitiveMarkers)
    }
    if containsAny(text, ["source app", "source application", "bundle id", "bundle identifier"]) {
      preprocessors.insert(.filterSourceApplications)
    }
    if contentKinds.contains(.image) || containsAny(text, ["dedupe", "fingerprint", "duplicate"]) {
      preprocessors.insert(.dedupeByFingerprint)
    }
    if source == .manualReviewTextPaste || source == .reviewScreenshotPaste
      || containsAny(text, ["github", "pull request", "pr link"])
    {
      preprocessors.insert(.normalizeGitHubPullRequestLinks)
      preprocessors.insert(.dedupePullRequests)
    }
    return AutomationPolicyPreprocessor.allCases.filter { preprocessors.contains($0) }
  }

  static func actions(
    for source: AutomationPolicyEventSource,
    contentKinds: Set<AutomationClipboardContentKind>,
    text: String
  ) -> [AutomationPolicyAction] {
    var actions: Set<AutomationPolicyAction> = [.recordMetadata]
    if contentKinds.contains(.image) {
      actions.insert(.ocrImage)
      actions.insert(.rememberRecentScan)
    }
    if source == .manualReviewTextPaste || source == .reviewScreenshotPaste
      || containsAny(text, ["github", "pull request", "pr link"])
    {
      populateReviewActions(into: &actions, source: source, text: text)
    }
    if containsAny(text, ["feedback", "haptic", "toast", "notify", "notification"]) {
      actions.insert(.showFeedback)
    }
    if containsAny(text, ["activity toast", "progress toast", "show spinner", "show progress"]) {
      actions.insert(.showActivityToast)
    }
    if containsAny(text, ["update activity toast", "update progress", "change toast"]) {
      actions.insert(.updateActivityToast)
    }
    if containsAny(
      text,
      ["hide activity toast", "hide progress", "hide spinner", "dismiss toast"]
    ) {
      actions.insert(.hideActivityToast)
    }
    if containsAny(text, ["debugging", "debug route", "open dashboard", "show dashboard"]) {
      actions.insert(.openDashboardDebugging)
    }
    if source != .clipboard && contentKinds.contains(.image) {
      actions.insert(.showFeedback)
    }
    return AutomationPolicyAction.allCases.filter { actions.contains($0) }
  }

  private static func populateReviewActions(
    into actions: inout Set<AutomationPolicyAction>,
    source: AutomationPolicyEventSource,
    text: String
  ) {
    actions.insert(.extractGitHubPullRequests)
    if source == .reviewScreenshotPaste {
      actions.insert(.resolveReviewPullRequests)
      actions.insert(.copyExtractedGitHubPullRequestURLs)
      actions.insert(.copyReviewPullRequestList)
    }
    if containsAny(text, ["card", "cards", "summary", "preview", "inspect"]) {
      actions.insert(.previewReviewApprovals)
    }
    if containsAny(text, ["ask", "prompt", "confirm", "approval prompt"]) {
      actions.insert(.promptReviewApprovals)
    }
    if containsAny(text, ["immediately approve", "approve immediately", "without prompt"]) {
      actions.insert(.approveReviewPullRequests)
    }
    if containsAny(text, ["auto policy", "reviews policy", "conditions", "conditional"]) {
      actions.insert(.runReviewPolicy)
    }
    if !actions.contains(.previewReviewApprovals)
      && !actions.contains(.promptReviewApprovals)
      && !actions.contains(.approveReviewPullRequests)
      && !actions.contains(.runReviewPolicy)
    {
      actions.insert(.previewReviewApprovals)
      actions.insert(.promptReviewApprovals)
    }
  }

  static func postprocessors(
    actions: [AutomationPolicyAction],
    text: String
  ) -> [AutomationPolicyPostprocessor] {
    var postprocessors: Set<AutomationPolicyPostprocessor> = [.auditEvent]
    if actions.contains(.ocrImage) || containsAny(text, ["cleanup", "clean up"]) {
      postprocessors.insert(.sourceSpecificTextCleanup)
    }
    if actions.contains(.rememberRecentScan) || containsAny(text, ["persist", "recent"]) {
      postprocessors.insert(.persistResult)
    }
    return AutomationPolicyPostprocessor.allCases.filter { postprocessors.contains($0) }
  }
}

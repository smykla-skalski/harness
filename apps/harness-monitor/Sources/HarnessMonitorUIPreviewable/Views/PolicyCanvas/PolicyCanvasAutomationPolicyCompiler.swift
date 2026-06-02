import Foundation
import HarnessMonitorKit
import SwiftUI

public struct PolicyCanvasAutomationPolicyCompilation: Equatable, Sendable {
  static let empty = Self(policies: [], diagnostics: [], policyBySourceNodeID: [:])

  public var policies: [AutomationPolicy]
  var diagnostics: [PolicyCanvasAutomationPolicyDiagnostic]
  var policyBySourceNodeID: [String: AutomationPolicy]

  public var summaryText: String {
    guard !policies.isEmpty else {
      return "No enforceable automation policies"
    }
    let noun = policies.count == 1 ? "policy" : "policies"
    return "\(policies.count) enforceable automation \(noun)"
  }

  func policy(compiledFrom nodeID: String) -> AutomationPolicy? {
    policyBySourceNodeID[nodeID]
  }
}

struct PolicyCanvasAutomationPolicyDiagnostic: Equatable, Identifiable, Sendable {
  let id: String
  let message: String
}

public enum PolicyCanvasAutomationPolicyCompiler {
  static func compile(
    nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge]
  ) -> PolicyCanvasAutomationPolicyCompilation {
    let sourceNodes = nodes.compactMap { node -> PolicyCanvasAutomationSource? in
      if isAutomationSourceNode(node), let binding = node.automationBinding {
        return PolicyCanvasAutomationSource(
          node: node,
          eventSource: binding.resolvedEventSource,
          binding: binding
        )
      }
      guard let source = eventSource(for: node) else {
        return nil
      }
      return PolicyCanvasAutomationSource(node: node, eventSource: source, binding: nil)
    }

    var diagnostics: [PolicyCanvasAutomationPolicyDiagnostic] = []
    if sourceNodes.isEmpty {
      diagnostics.append(
        PolicyCanvasAutomationPolicyDiagnostic(
          id: "missing-source",
          message: [
            "Add a source node named Clipboard, Manual Paste, Review Text Paste,",
            "Review Screenshot Paste,",
            "Drag and Drop, File Picker, or Screenshot Folder.",
          ].joined(separator: " ")
        )
      )
    }

    let sortedSources = sourceNodes.sorted {
      if $0.node.position.y == $1.node.position.y {
        return $0.node.position.x < $1.node.position.x
      }
      return $0.node.position.y < $1.node.position.y
    }
    var usedPolicyIDs = Set<String>()
    var policyBySourceNodeID: [String: AutomationPolicy] = [:]
    policyBySourceNodeID.reserveCapacity(sortedSources.count)
    let policies = sortedSources.enumerated().map { offset, source in
      let policyID = uniquePolicyID(for: source, usedIDs: &usedPolicyIDs)
      let compiledPolicy = policy(
        for: source,
        policyID: policyID,
        priority: offset + 1,
        nodes: nodes,
        edges: edges
      )
      policyBySourceNodeID[source.node.id] = compiledPolicy
      return compiledPolicy
    }
    return PolicyCanvasAutomationPolicyCompilation(
      policies: policies,
      diagnostics: diagnostics,
      policyBySourceNodeID: policyBySourceNodeID
    )
  }

  private static func isAutomationSourceNode(_ node: PolicyCanvasNode) -> Bool {
    node.kind == .source || node.inputPorts.isEmpty
  }

  static func compile(
    document: TaskBoardPolicyPipelineDocument
  ) -> PolicyCanvasAutomationPolicyCompilation {
    let nodes = document.nodes.map {
      policyCanvasNode($0, layout: document.layout)
    }
    let edges = document.edges.compactMap { edge in
      policyCanvasEdge(edge, nodes: nodes, assignPreferredPortSides: false)
    }
    return compile(nodes: nodes, edges: edges)
  }

  static func slug(_ rawValue: String) -> String {
    let lowered = rawValue.lowercased()
    var characters: [Character] = []
    var lastWasSeparator = false
    for character in lowered {
      if character.isLetter || character.isNumber {
        characters.append(character)
        lastWasSeparator = false
      } else if !lastWasSeparator {
        characters.append("-")
        lastWasSeparator = true
      }
    }
    return String(characters).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private static func policy(
    for source: PolicyCanvasAutomationSource,
    policyID: String,
    priority: Int,
    nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge]
  ) -> AutomationPolicy {
    let reachableNodes = reachableNodes(from: source.node.id, nodes: nodes, edges: edges)
    let text = graphText(reachableNodes: reachableNodes, edges: edges)
    let contribution = automationContribution(
      from: reachableNodes,
      sourceNodeID: source.node.id
    )
    let contentKinds = contentKinds(from: text)
    let actions = actions(for: source.eventSource, contentKinds: contentKinds, text: text)
    let policyName =
      source.node.title.isEmpty ? "\(source.eventSource.title) Canvas Policy" : source.node.title
    if let binding = source.binding {
      return binding.automationPolicy(
        id: policyID,
        name: policyName,
        defaultPriority: priority
      )
      .applying(contribution)
    }
    return AutomationPolicy(
      id: policyID,
      name: policyName,
      eventSource: source.eventSource,
      isEnabled: true,
      priority: priority,
      match: AutomationPolicyMatch(
        contentKinds: contentKinds,
        sourceAppFilter: sourceAppFilter(from: text)
      ),
      preprocessors: preprocessors(
        for: source.eventSource,
        contentKinds: contentKinds,
        text: text
      ),
      actions: actions,
      postprocessors: postprocessors(actions: actions, text: text),
      ocrConfiguration: source.eventSource == .reviewScreenshotPaste
        ? AutomationPolicyOCRConfiguration()
        : nil,
      reviewPullRequestExtraction: source.eventSource == .reviewScreenshotPaste
        ? ReviewPullRequestExtractionConfiguration()
        : nil
    )
    .applying(contribution)
  }

  private static func uniquePolicyID(
    for source: PolicyCanvasAutomationSource,
    usedIDs: inout Set<String>
  ) -> String {
    let baseID =
      AutomationPolicyDocument.canvasPolicyIDPrefix
      + source.eventSource.rawValue
      + "."
      + slug(source.node.id)
    guard !usedIDs.contains(baseID) else {
      var candidate = baseID + "-" + stableHexSuffix(source.node.id)
      var counter = 2
      while usedIDs.contains(candidate) {
        candidate = baseID + "-" + stableHexSuffix(source.node.id + ":\(counter)")
        counter += 1
      }
      usedIDs.insert(candidate)
      return candidate
    }
    usedIDs.insert(baseID)
    return baseID
  }

  private static func stableHexSuffix(_ rawValue: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in rawValue.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x0100_0000_01b3
    }
    return String(hash, radix: 16)
  }

  private static func eventSource(for node: PolicyCanvasNode) -> AutomationPolicyEventSource? {
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

  private static func reachableNodes(
    from sourceID: String,
    nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge]
  ) -> [PolicyCanvasNode] {
    let outgoing = Dictionary(grouping: edges, by: \.source.nodeID)
    var visited = Set<String>()
    var pending = [sourceID]
    var cursor = 0
    while cursor < pending.count {
      let current = pending[cursor]
      cursor += 1
      guard visited.insert(current).inserted else {
        continue
      }
      for edge in outgoing[current] ?? [] where !visited.contains(edge.target.nodeID) {
        pending.append(edge.target.nodeID)
      }
    }
    return nodes.filter { visited.contains($0.id) }
  }

  private static func graphText(
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

  private static func contentKinds(from text: String) -> Set<AutomationClipboardContentKind> {
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

  private static func preprocessors(
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

  private static func actions(
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
      actions.insert(.extractGitHubPullRequests)
      if source == .reviewScreenshotPaste {
        actions.insert(.resolveReviewPullRequests)
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
    if containsAny(text, ["feedback", "haptic", "toast", "notify", "notification"]) {
      actions.insert(.showFeedback)
    }
    if containsAny(text, ["debugging", "debug route", "open dashboard", "show dashboard"]) {
      actions.insert(.openDashboardDebugging)
    }
    if source != .clipboard && contentKinds.contains(.image) {
      actions.insert(.showFeedback)
    }
    return AutomationPolicyAction.allCases.filter { actions.contains($0) }
  }

  private static func postprocessors(
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

extension PolicyCanvasViewModel {
  var automationPolicyCompilation: PolicyCanvasAutomationPolicyCompilation {
    cachedAutomationPolicyCompilation
  }
}

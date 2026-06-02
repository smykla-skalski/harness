import Foundation
import HarnessMonitorKit
import Observation

public enum ClipboardAutomationRuntimeState: Equatable, Sendable {
  case off
  case watching
  case paused(String)
  case denied
  case skipped(String)
  case matched(String)
  case failed(String)

  public var label: String {
    switch self {
    case .off: "Clipboard policies off"
    case .watching: "Clipboard policies watching"
    case .paused(let reason): "Clipboard policies paused: \(reason)"
    case .denied: "Clipboard access denied"
    case .skipped(let reason): "Clipboard skipped: \(reason)"
    case .matched(let policy): "Clipboard matched: \(policy)"
    case .failed(let message): "Clipboard failed: \(message)"
    }
  }
}

@MainActor
@Observable
public final class AutomationPolicyCenter {
  public static let shared = AutomationPolicyCenter()

  public private(set) var document: AutomationPolicyDocument
  public private(set) var clipboardRuntimeState: ClipboardAutomationRuntimeState = .off
  public private(set) var lastClipboardEventSummary: String?
  public private(set) var lastClipboardEventAt: Date?
  public private(set) var recentAutomationEvents: [AutomationPolicyEventRecord]

  @ObservationIgnored private let fileURL: URL
  @ObservationIgnored private let fileManager: FileManager
  @ObservationIgnored private let encoder: JSONEncoder
  @ObservationIgnored private let decoder: JSONDecoder
  @ObservationIgnored private let eventStore: AutomationPolicyEventStore

  init(
    fileURL: URL = HarnessMonitorPaths.harnessRoot()
      .appendingPathComponent("policies", isDirectory: true)
      .appendingPathComponent("automation-policies.json"),
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    document = Self.loadDocument(
      from: fileURL,
      fileManager: fileManager,
      decoder: decoder
    )
    eventStore = AutomationPolicyEventStore(
      directoryURL: fileURL.deletingLastPathComponent(),
      fileManager: fileManager
    )
    recentAutomationEvents = eventStore.load()
  }

  public var isAutomationEnabled: Bool {
    document.isEnabled
  }

  public var isClipboardMonitorEnabled: Bool {
    document.isEnabled && document.policies(for: .clipboard).contains(where: \.isEnabled)
  }

  public var clipboardPolicy: AutomationPolicy {
    document.policy(for: .clipboard)
  }

  public var policySummaryText: String {
    let activeCount = document.policies.count { document.isEnabled && $0.isEnabled }
    return "\(activeCount) of \(document.policies.count) policies enabled"
  }

  public func policy(for source: AutomationPolicyEventSource) -> AutomationPolicy {
    document.policy(for: source)
  }

  public func policy(id: String) -> AutomationPolicy? {
    document.policy(id: id)
  }

  public func createPolicy(for source: AutomationPolicyEventSource) {
    guard source != .manualReviewTextPaste, source != .reviewScreenshotPaste else {
      return
    }
    let priority = (document.policies.map(\.priority).max() ?? 0) + 10
    let matchKinds: Set<AutomationClipboardContentKind> =
      switch source {
      case .clipboard:
        [.image, .text, .file, .url]
      case .manualReviewTextPaste:
        [.text, .url]
      case .reviewScreenshotPaste:
        [.image]
      case .manualOCRPaste, .ocrDrop, .ocrFilePicker, .screenshotFolder:
        [.image]
      }
    let actions: [AutomationPolicyAction] =
      switch source {
      case .clipboard:
        [.recordMetadata]
      case .manualReviewTextPaste:
        [
          .extractGitHubPullRequests,
          .previewReviewApprovals,
          .promptReviewApprovals,
          .recordMetadata,
        ]
      case .reviewScreenshotPaste:
        [
          .ocrImage,
          .extractGitHubPullRequests,
          .resolveReviewPullRequests,
          .copyReviewPullRequestList,
          .previewReviewApprovals,
          .recordMetadata,
        ]
      case .manualOCRPaste, .ocrDrop, .ocrFilePicker, .screenshotFolder:
        [.ocrImage, .rememberRecentScan, .recordMetadata]
      }
    let ocrConfiguration: AutomationPolicyOCRConfiguration? =
      source == .reviewScreenshotPaste ? AutomationPolicyOCRConfiguration() : nil
    let reviewPullRequestExtraction: ReviewPullRequestExtractionConfiguration? =
      source == .reviewScreenshotPaste ? ReviewPullRequestExtractionConfiguration() : nil
    let policy = AutomationPolicy(
      id: "policy.\(source.rawValue).\(UUID().uuidString)",
      name: "\(source.title) Rule",
      eventSource: source,
      isEnabled: true,
      priority: priority,
      match: AutomationPolicyMatch(contentKinds: matchKinds),
      preprocessors: Self.defaultPreprocessors(for: source),
      actions: actions,
      postprocessors: [.auditEvent],
      ocrConfiguration: ocrConfiguration,
      reviewPullRequestExtraction: reviewPullRequestExtraction
    )
    replacePolicy(policy)
    updateClipboardRuntimeStateAfterPolicyChange()
  }

  public func deletePolicy(_ policyID: String) {
    updateDocument(document.deletingPolicy(id: policyID))
    updateClipboardRuntimeStateAfterPolicyChange()
  }

  public func setAutomationEnabled(_ isEnabled: Bool) {
    updateDocument(document.replacingEnabled(isEnabled))
    updateClipboardRuntimeStateAfterPolicyChange()
  }

  public func setPolicyEnabled(_ policyID: String, isEnabled: Bool) {
    guard var policy = document.policies.first(where: { $0.id == policyID }) else {
      return
    }
    policy.isEnabled = isEnabled
    replacePolicy(policy)
    if policy.eventSource == .clipboard {
      updateClipboardRuntimeStateAfterPolicyChange()
    }
  }

  public func setPoliciesEnabled(
    for source: AutomationPolicyEventSource,
    isEnabled: Bool
  ) {
    var nextDocument = document
    nextDocument.policies = nextDocument.policies.map { policy in
      guard policy.eventSource == source else {
        return policy
      }
      var nextPolicy = policy
      nextPolicy.isEnabled = isEnabled
      return nextPolicy
    }
    nextDocument.updatedAt = Date()
    updateDocument(nextDocument)
    if source == .clipboard {
      updateClipboardRuntimeStateAfterPolicyChange()
    }
  }

  public func setPolicyName(_ name: String, for policyID: String) {
    guard var policy = document.policies.first(where: { $0.id == policyID }) else {
      return
    }
    policy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if policy.name.isEmpty {
      policy.name = policy.eventSource.title
    }
    replacePolicy(policy)
  }

  public func setPolicyEventSource(_ source: AutomationPolicyEventSource, for policyID: String) {
    guard !AutomationPolicyDocument.defaultPolicyIDs.contains(policyID) else {
      return
    }
    guard source != .manualReviewTextPaste, source != .reviewScreenshotPaste else {
      return
    }
    guard var policy = document.policies.first(where: { $0.id == policyID }) else {
      return
    }
    policy.eventSource = source
    replacePolicy(policy)
    updateClipboardRuntimeStateAfterPolicyChange()
  }

  public func setPolicyPriority(_ priority: Int, for policyID: String) {
    guard var policy = document.policies.first(where: { $0.id == policyID }) else {
      return
    }
    policy.priority = priority
    replacePolicy(policy)
  }

  public func setSourceAppMode(_ mode: AutomationSourceAppMode, for policyID: String) {
    guard var policy = document.policies.first(where: { $0.id == policyID }) else {
      return
    }
    policy.match.sourceAppFilter.mode = mode
    replacePolicy(policy)
  }

  public func setAllowedSourceAppIdentifiers(_ identifiers: [String], for policyID: String) {
    guard var policy = document.policies.first(where: { $0.id == policyID }) else {
      return
    }
    policy.match.sourceAppFilter.allowedBundleIdentifiers =
      AutomationSourceAppFilter.normalizedIdentifiers(identifiers)
    replacePolicy(policy)
  }

  public func setDeniedSourceAppIdentifiers(_ identifiers: [String], for policyID: String) {
    guard var policy = document.policies.first(where: { $0.id == policyID }) else {
      return
    }
    policy.match.sourceAppFilter.deniedBundleIdentifiers =
      AutomationSourceAppFilter.normalizedIdentifiers(identifiers)
    replacePolicy(policy)
  }

  public func setAction(
    _ action: AutomationPolicyAction,
    isEnabled: Bool,
    for policyID: String
  ) {
    guard var policy = document.policies.first(where: { $0.id == policyID }) else {
      return
    }
    policy.actions = toggled(policy.actions, element: action, isEnabled: isEnabled)
    replacePolicy(policy)
  }

  public func setContentKind(
    _ kind: AutomationClipboardContentKind,
    isEnabled: Bool,
    for policyID: String
  ) {
    guard var policy = document.policies.first(where: { $0.id == policyID }) else {
      return
    }
    if isEnabled {
      policy.match.contentKinds.insert(kind)
    } else {
      policy.match.contentKinds.remove(kind)
    }
    replacePolicy(policy)
  }

  public func setPreprocessor(
    _ preprocessor: AutomationPolicyPreprocessor,
    isEnabled: Bool,
    for policyID: String
  ) {
    guard var policy = document.policies.first(where: { $0.id == policyID }) else {
      return
    }
    policy.preprocessors = toggled(
      policy.preprocessors,
      element: preprocessor,
      isEnabled: isEnabled
    )
    replacePolicy(policy)
  }

  public func setPostprocessor(
    _ postprocessor: AutomationPolicyPostprocessor,
    isEnabled: Bool,
    for policyID: String
  ) {
    guard var policy = document.policies.first(where: { $0.id == policyID }) else {
      return
    }
    policy.postprocessors = toggled(
      policy.postprocessors,
      element: postprocessor,
      isEnabled: isEnabled
    )
    replacePolicy(policy)
  }

  func updateClipboardRuntimeState(_ state: ClipboardAutomationRuntimeState) {
    clipboardRuntimeState = state
  }

  func recordClipboardEvent(summary: String) {
    lastClipboardEventSummary = summary
    lastClipboardEventAt = Date()
  }

  func recordAutomationEvent(_ event: AutomationPolicyEventRecord) {
    recentAutomationEvents = eventStore.record(event)
    if event.source == .clipboard {
      recordClipboardEvent(summary: event.summary)
    }
  }

  func clearAutomationEvents() {
    recentAutomationEvents = eventStore.clear()
  }

  func replacePolicy(_ policy: AutomationPolicy) {
    updateDocument(document.replacingPolicy(policy))
  }

  public func replaceCanvasPolicies(_ policies: [AutomationPolicy]) {
    updateDocument(document.replacingCanvasPolicies(policies))
    updateClipboardRuntimeStateAfterPolicyChange()
  }

  private func updateDocument(_ nextDocument: AutomationPolicyDocument) {
    document = nextDocument
    writeDocument(nextDocument)
  }

  private func toggled<Element: Equatable>(
    _ values: [Element],
    element: Element,
    isEnabled: Bool
  ) -> [Element] {
    if isEnabled {
      guard !values.contains(element) else {
        return values
      }
      return values + [element]
    }
    return values.filter { $0 != element }
  }

  private func updateClipboardRuntimeStateAfterPolicyChange() {
    updateClipboardRuntimeState(isClipboardMonitorEnabled ? .watching : .off)
  }

  private static func defaultPreprocessors(
    for source: AutomationPolicyEventSource
  ) -> [AutomationPolicyPreprocessor] {
    switch source {
    case .clipboard:
      [.respectPasteboardPrivacy, .skipSensitiveMarkers, .filterSourceApplications]
    case .manualReviewTextPaste:
      [.normalizeGitHubPullRequestLinks, .dedupePullRequests]
    case .reviewScreenshotPaste:
      [.dedupeByFingerprint, .normalizeGitHubPullRequestLinks, .dedupePullRequests]
    case .manualOCRPaste, .ocrDrop, .ocrFilePicker, .screenshotFolder:
      [.dedupeByFingerprint]
    }
  }

  private static func loadDocument(
    from fileURL: URL,
    fileManager: FileManager,
    decoder: JSONDecoder
  ) -> AutomationPolicyDocument {
    guard
      fileManager.fileExists(atPath: fileURL.path),
      let data = try? Data(contentsOf: fileURL),
      let document = try? decoder.decode(AutomationPolicyDocument.self, from: data)
    else {
      return AutomationPolicyDocument()
    }
    return AutomationPolicyDocument(
      version: document.version,
      isEnabled: document.isEnabled,
      policies: document.policies.filter(Self.shouldPersistPolicy),
      updatedAt: document.updatedAt
    )
  }

  private static func shouldPersistPolicy(_ policy: AutomationPolicy) -> Bool {
    guard !policy.id.hasPrefix(AutomationPolicyDocument.canvasPolicyIDPrefix) else {
      return false
    }
    return policy.eventSource != .manualReviewTextPaste
      && policy.eventSource != .reviewScreenshotPaste
  }

  private func writeDocument(_ document: AutomationPolicyDocument) {
    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let persisted = AutomationPolicyDocument(
        version: document.version,
        isEnabled: document.isEnabled,
        policies: document.policies.filter(Self.shouldPersistPolicy),
        updatedAt: document.updatedAt
      )
      let data = try encoder.encode(persisted)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      clipboardRuntimeState = .failed(error.localizedDescription)
    }
  }
}

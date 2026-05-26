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

  @ObservationIgnored private let fileURL: URL
  @ObservationIgnored private let fileManager: FileManager
  @ObservationIgnored private let encoder: JSONEncoder
  @ObservationIgnored private let decoder: JSONDecoder

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
  }

  public var isAutomationEnabled: Bool {
    document.isEnabled
  }

  public var isClipboardMonitorEnabled: Bool {
    document.isEnabled && clipboardPolicy.isEnabled
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

  public func setAutomationEnabled(_ isEnabled: Bool) {
    updateDocument(document.replacingEnabled(isEnabled))
    updateClipboardRuntimeState(isEnabled && clipboardPolicy.isEnabled ? .watching : .off)
  }

  public func setPolicyEnabled(_ policyID: String, isEnabled: Bool) {
    guard var policy = document.policies.first(where: { $0.id == policyID }) else {
      return
    }
    policy.isEnabled = isEnabled
    replacePolicy(policy)
    if policy.eventSource == .clipboard {
      updateClipboardRuntimeState(document.isEnabled && isEnabled ? .watching : .off)
    }
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

  func decision(
    for source: AutomationPolicyEventSource,
    contentKinds: Set<AutomationClipboardContentKind>,
    sourceApplication: AutomationSourceApplication? = nil,
    containsSensitiveContent: Bool = false,
    accessBehaviorDescription: String? = nil
  ) -> AutomationPolicyDecision {
    let policy = document.policy(for: source)
    guard policy.isEnabled else {
      return AutomationPolicyDecision(
        policy: policy,
        isAllowed: false,
        reason: "\(policy.name) is disabled"
      )
    }
    guard document.isEnabled || source != .clipboard else {
      return AutomationPolicyDecision(
        policy: policy,
        isAllowed: false,
        reason: "Automation policies are disabled"
      )
    }
    if policy.hasPreprocessor(.respectPasteboardPrivacy),
      accessBehaviorDescription == "alwaysDeny"
    {
      return AutomationPolicyDecision(
        policy: policy,
        isAllowed: false,
        reason: "Pasteboard access is denied in System Settings"
      )
    }
    if policy.hasPreprocessor(.skipSensitiveMarkers), containsSensitiveContent {
      return AutomationPolicyDecision(
        policy: policy,
        isAllowed: false,
        reason: "Pasteboard item is marked concealed or transient"
      )
    }
    if policy.hasPreprocessor(.filterSourceApplications),
      !policy.match.sourceAppFilter.allows(sourceApplication)
    {
      return AutomationPolicyDecision(
        policy: policy,
        isAllowed: false,
        reason: "Source application is not allowed"
      )
    }
    guard !policy.match.contentKinds.isDisjoint(with: contentKinds) else {
      return AutomationPolicyDecision(
        policy: policy,
        isAllowed: false,
        reason: "No matching content kinds"
      )
    }
    return AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil)
  }

  func updateClipboardRuntimeState(_ state: ClipboardAutomationRuntimeState) {
    clipboardRuntimeState = state
  }

  func recordClipboardEvent(summary: String) {
    lastClipboardEventSummary = summary
    lastClipboardEventAt = Date()
  }

  private func replacePolicy(_ policy: AutomationPolicy) {
    updateDocument(document.replacingPolicy(policy))
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
      policies: document.policies,
      updatedAt: document.updatedAt
    )
  }

  private func writeDocument(_ document: AutomationPolicyDocument) {
    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try encoder.encode(document)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      clipboardRuntimeState = .failed(error.localizedDescription)
    }
  }
}

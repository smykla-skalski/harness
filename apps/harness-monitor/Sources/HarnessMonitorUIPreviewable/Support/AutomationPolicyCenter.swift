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

  @ObservationIgnored private let eventStore: AutomationPolicyEventStore

  init(
    eventDirectoryURL: URL = HarnessMonitorPaths.harnessRoot()
      .appendingPathComponent("policies", isDirectory: true),
    fileManager: FileManager = .default
  ) {
    document = AutomationPolicyDocument()
    eventStore = AutomationPolicyEventStore(
      directoryURL: eventDirectoryURL,
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

  public func setAutomationEnabled(_ isEnabled: Bool) {
    updateDocument(document.replacingEnabled(isEnabled))
    updateClipboardRuntimeStateAfterPolicyChange()
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
    updateClipboardRuntimeStateAfterPolicyChange()
  }

  public func replaceCanvasPolicies(_ policies: [AutomationPolicy]) {
    updateDocument(document.replacingCanvasPolicies(policies))
    updateClipboardRuntimeStateAfterPolicyChange()
  }

  private func updateDocument(_ nextDocument: AutomationPolicyDocument) {
    document = nextDocument
  }

  private func updateClipboardRuntimeStateAfterPolicyChange() {
    updateClipboardRuntimeState(isClipboardMonitorEnabled ? .watching : .off)
  }
}

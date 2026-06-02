import Foundation
import Observation
import HarnessMonitorPolicyCanvasAlgorithms

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

public struct PolicyCanvasAutomationStoreState: Sendable {
  public var document: AutomationPolicyDocument
  public var clipboardRuntimeState: ClipboardAutomationRuntimeState
  public var lastClipboardEventSummary: String?
  public var lastClipboardEventAt: Date?
  public var recentAutomationEvents: [AutomationPolicyEventRecord]

  public init(
    document: AutomationPolicyDocument = AutomationPolicyDocument(),
    clipboardRuntimeState: ClipboardAutomationRuntimeState = .off,
    lastClipboardEventSummary: String? = nil,
    lastClipboardEventAt: Date? = nil,
    recentAutomationEvents: [AutomationPolicyEventRecord] = []
  ) {
    self.document = document
    self.clipboardRuntimeState = clipboardRuntimeState
    self.lastClipboardEventSummary = lastClipboardEventSummary
    self.lastClipboardEventAt = lastClipboardEventAt
    self.recentAutomationEvents = recentAutomationEvents
  }
}

@MainActor
@Observable
public final class PolicyCanvasAutomationStore {
  public static let shared = PolicyCanvasAutomationStore()

  public private(set) var document: AutomationPolicyDocument
  public private(set) var clipboardRuntimeState: ClipboardAutomationRuntimeState
  public private(set) var lastClipboardEventSummary: String?
  public private(set) var lastClipboardEventAt: Date?
  public private(set) var recentAutomationEvents: [AutomationPolicyEventRecord]

  private let setAutomationEnabledHandler: ((Bool) -> PolicyCanvasAutomationStoreState)?
  private let replaceCanvasPoliciesHandler: (([AutomationPolicy]) -> PolicyCanvasAutomationStoreState)?

  public init(
    state: PolicyCanvasAutomationStoreState = PolicyCanvasAutomationStoreState(),
    setAutomationEnabled: ((Bool) -> PolicyCanvasAutomationStoreState)? = nil,
    replaceCanvasPolicies: (([AutomationPolicy]) -> PolicyCanvasAutomationStoreState)? = nil
  ) {
    document = state.document
    clipboardRuntimeState = state.clipboardRuntimeState
    lastClipboardEventSummary = state.lastClipboardEventSummary
    lastClipboardEventAt = state.lastClipboardEventAt
    recentAutomationEvents = state.recentAutomationEvents
    setAutomationEnabledHandler = setAutomationEnabled
    replaceCanvasPoliciesHandler = replaceCanvasPolicies
  }

  public var isAutomationEnabled: Bool {
    document.isEnabled
  }

  public func replaceState(_ state: PolicyCanvasAutomationStoreState) {
    document = state.document
    clipboardRuntimeState = state.clipboardRuntimeState
    lastClipboardEventSummary = state.lastClipboardEventSummary
    lastClipboardEventAt = state.lastClipboardEventAt
    recentAutomationEvents = state.recentAutomationEvents
  }

  public func setAutomationEnabled(_ isEnabled: Bool) {
    if let state = setAutomationEnabledHandler?(isEnabled) {
      replaceState(state)
      return
    }
    document = document.replacingEnabled(isEnabled)
  }

  public func replaceCanvasPolicies(_ policies: [AutomationPolicy]) {
    if let state = replaceCanvasPoliciesHandler?(policies) {
      replaceState(state)
      return
    }
    document = document.replacingCanvasPolicies(policies)
  }
}

import AppKit
import SwiftUI

public struct ClipboardAutomationPolicyHost: View {
  @Environment(\.openWindow)
  private var openWindow
  @State private var center = AutomationPolicyCenter.shared
  @State private var monitor = ClipboardAutomationMonitor()

  public init() {}

  public var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .task {
        monitor.start(center: center) { dispatch in
          ClipboardAutomationCommands.apply(dispatch, openWindow: openWindow)
        }
      }
      .onDisappear {
        monitor.stop(center: center)
      }
  }
}

@MainActor
public final class ClipboardAutomationPolicyService {
  private let center = AutomationPolicyCenter.shared
  private let monitor = ClipboardAutomationMonitor()

  public init() {}

  public func start(openWindow: OpenWindowAction) {
    monitor.start(center: center) { dispatch in
      ClipboardAutomationCommands.apply(dispatch, openWindow: openWindow)
    }
  }

  public func stop() {
    monitor.stop(center: center)
  }
}

@MainActor
public enum ClipboardAutomationCommands {
  public static func captureCurrentClipboard(openWindow: OpenWindowAction) {
    Task { @MainActor in
      guard
        let dispatch = await ClipboardAutomationEvaluator.dispatchForCurrentClipboard(
          center: AutomationPolicyCenter.shared,
          reason: .manualCapture,
          observedSourceApplication: ClipboardAutomationSourceApplicationResolver.current(
            confidence: "manual-capture-frontmost-application"
          )
        )
      else {
        return
      }
      apply(dispatch, openWindow: openWindow)
    }
  }

  static func apply(_ dispatch: ClipboardAutomationDispatch, openWindow: OpenWindowAction) {
    if !dispatch.candidates.isEmpty {
      if dispatch.shouldOpenDashboardDebugging {
        DashboardDebuggingOCRPasteboardRequests.requestAutomationClipboard(
          candidates: dispatch.candidates,
          policyDecision: dispatch.policyDecision
        )
      } else {
        Task { @MainActor in
          await ClipboardAutomationBackgroundOCRProcessor.process(
            dispatch,
            center: AutomationPolicyCenter.shared
          )
        }
      }
    }
    if dispatch.shouldOpenDashboardDebugging {
      routeToDebugging(openWindow: openWindow)
    }
  }

  static func routeToDebugging(openWindow: OpenWindowAction) {
    UserDefaults.standard.set(
      DashboardWindowRoute.debugging.rawValue,
      forKey: DashboardRouteRestorationDefaults.storageKey
    )
    if let history = GlobalWindowNavigationHistoryRegistry.current {
      history.requestDashboardRoute(.debugging)
    } else {
      openWindow.openHarnessDashboardWindow()
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}

@MainActor
final class ClipboardAutomationMonitor {
  private var task: Task<Void, Never>?
  private var lastChangeCount: Int?

  func start(
    center: AutomationPolicyCenter,
    onDispatch: @escaping @MainActor (ClipboardAutomationDispatch) -> Void
  ) {
    guard task == nil else {
      return
    }
    lastChangeCount = NSPasteboard.general.changeCount
    task = Task { @MainActor in
      await run(center: center, onDispatch: onDispatch)
    }
  }

  func stop(center: AutomationPolicyCenter? = nil) {
    task?.cancel()
    task = nil
    center?.updateClipboardRuntimeState(.off)
  }

  private func run(
    center: AutomationPolicyCenter,
    onDispatch: @escaping @MainActor (ClipboardAutomationDispatch) -> Void
  ) async {
    while !Task.isCancelled {
      await observe(center: center, onDispatch: onDispatch)
      try? await Task.sleep(for: .milliseconds(pollIntervalMilliseconds(center: center)))
    }
  }

  private func observe(
    center: AutomationPolicyCenter,
    onDispatch: @escaping @MainActor (ClipboardAutomationDispatch) -> Void
  ) async {
    guard center.isClipboardMonitorEnabled else {
      center.updateClipboardRuntimeState(.off)
      lastChangeCount = NSPasteboard.general.changeCount
      return
    }

    center.updateClipboardRuntimeState(.watching)
    let pasteboard = NSPasteboard.general
    let changeCount = pasteboard.changeCount
    guard changeCount != lastChangeCount else {
      return
    }
    lastChangeCount = changeCount
    let observedSourceApplication = ClipboardAutomationSourceApplicationResolver.current(
      confidence: "frontmost-application-at-change"
    )

    try? await Task.sleep(for: .milliseconds(120))
    guard !Task.isCancelled else {
      return
    }
    guard
      Self.shouldEvaluateObservedChange(
        observedChangeCount: changeCount,
        currentChangeCount: pasteboard.changeCount
      )
    else {
      return
    }
    guard
      let dispatch = await ClipboardAutomationEvaluator.dispatchForCurrentClipboard(
        center: center,
        reason: .poll(changeCount: changeCount),
        observedSourceApplication: observedSourceApplication
      )
    else {
      return
    }
    onDispatch(dispatch)
  }

  private func pollIntervalMilliseconds(center: AutomationPolicyCenter) -> Int {
    center.isClipboardMonitorEnabled ? 700 : 1_400
  }
}

enum ClipboardAutomationEvaluationReason: Equatable {
  case poll(changeCount: Int)
  case manualCapture
}

struct ClipboardAutomationDispatch {
  let candidates: [DashboardOCRImageCandidate]
  let shouldOpenDashboardDebugging: Bool
  let policyDecision: AutomationPolicyDecision
  let sourceApplication: AutomationSourceApplication?
}

@MainActor
enum ClipboardAutomationEvaluator {
  static func dispatchForCurrentClipboard(
    center: AutomationPolicyCenter,
    reason: ClipboardAutomationEvaluationReason,
    observedSourceApplication: AutomationSourceApplication? = nil
  ) async -> ClipboardAutomationDispatch? {
    let pasteboard = NSPasteboard.general
    let snapshot = await ClipboardAutomationSnapshot.make(
      from: pasteboard,
      reason: reason,
      observedSourceApplication: observedSourceApplication
    )
    let decision = center.decision(
      for: .clipboard,
      contentKinds: snapshot.contentKinds,
      sourceApplication: snapshot.sourceApplication,
      containsSensitiveContent: snapshot.containsSensitiveContent,
      accessBehaviorDescription: snapshot.accessBehaviorDescription,
      allowsPasteboardPrompt: reason == .manualCapture
    )
    guard decision.isAllowed else {
      let result = AutomationPolicyExecutionPipeline.execute(
        snapshot.executionRequest(
          decision: decision,
          metadata: .empty,
          imageCandidates: []
        )
      )
      apply(result, center: center)
      return result.dispatch
    }

    let metadata = snapshot.readableMetadata(
      from: pasteboard,
      shouldRead: decision.shouldRecordMetadata
    )
    let candidates = readableImageCandidates(
      from: pasteboard,
      snapshot: snapshot,
      decision: decision
    )
    let result = AutomationPolicyExecutionPipeline.execute(
      snapshot.executionRequest(
        decision: decision,
        metadata: metadata,
        imageCandidates: candidates
      )
    )
    apply(result, center: center)
    return result.dispatch
  }

  private static func readableImageCandidates(
    from pasteboard: NSPasteboard,
    snapshot: ClipboardAutomationSnapshot,
    decision: AutomationPolicyDecision
  ) -> [DashboardOCRImageCandidate] {
    guard decision.shouldOCRImages else {
      return []
    }
    let candidates = DashboardOCRInputReader.candidates(fromPasteboard: pasteboard).map {
      $0.addingSourceMetadata(snapshot.sourceMetadata)
    }
    guard decision.policy.hasPreprocessor(.dedupeByFingerprint) else {
      return candidates
    }
    return DashboardOCRImageCandidate.mergedByFingerprint(candidates)
  }

  private static func apply(
    _ result: AutomationPolicyExecutionResult,
    center: AutomationPolicyCenter
  ) {
    center.updateClipboardRuntimeState(result.runtimeState)
    if let eventRecord = result.eventRecord {
      center.recordAutomationEvent(eventRecord)
    }
  }
}

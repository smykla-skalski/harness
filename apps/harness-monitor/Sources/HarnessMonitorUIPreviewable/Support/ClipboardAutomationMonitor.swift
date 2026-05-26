import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        monitor.stop()
      }
  }
}

@MainActor
public enum ClipboardAutomationCommands {
  public static func captureCurrentClipboard(openWindow: OpenWindowAction) {
    Task { @MainActor in
      guard
        let dispatch = await ClipboardAutomationEvaluator.dispatchForCurrentClipboard(
          center: AutomationPolicyCenter.shared,
          reason: .manualCapture
        )
      else {
        return
      }
      apply(dispatch, openWindow: openWindow)
    }
  }

  static func apply(_ dispatch: ClipboardAutomationDispatch, openWindow: OpenWindowAction) {
    let didQueue = DashboardDebuggingOCRPasteboardRequests.requestAutomationClipboard(
      candidates: dispatch.candidates
    )
    guard didQueue else {
      return
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

  func stop() {
    task?.cancel()
    task = nil
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

    try? await Task.sleep(for: .milliseconds(120))
    guard !Task.isCancelled else {
      return
    }
    guard
      let dispatch = await ClipboardAutomationEvaluator.dispatchForCurrentClipboard(
        center: center,
        reason: .poll(changeCount: changeCount)
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
}

@MainActor
enum ClipboardAutomationEvaluator {
  static func dispatchForCurrentClipboard(
    center: AutomationPolicyCenter,
    reason: ClipboardAutomationEvaluationReason
  ) async -> ClipboardAutomationDispatch? {
    let pasteboard = NSPasteboard.general
    let snapshot = await ClipboardAutomationSnapshot.make(from: pasteboard, reason: reason)
    let decision = center.decision(
      for: .clipboard,
      contentKinds: snapshot.contentKinds,
      sourceApplication: snapshot.sourceApplication,
      containsSensitiveContent: snapshot.containsSensitiveContent,
      accessBehaviorDescription: snapshot.accessBehaviorDescription
    )
    guard decision.isAllowed else {
      center.updateClipboardRuntimeState(.skipped(decision.reason ?? "No policy matched"))
      center.recordClipboardEvent(summary: snapshot.summary)
      return nil
    }
    guard decision.shouldOCRImages else {
      center.updateClipboardRuntimeState(.matched(decision.policy.name))
      center.recordClipboardEvent(summary: snapshot.summary)
      return nil
    }

    let candidates = DashboardOCRImageCandidate.mergedByFingerprint(
      DashboardOCRInputReader.candidates(fromPasteboard: pasteboard).map {
        $0.addingSourceMetadata(snapshot.sourceMetadata)
      }
    )
    guard !candidates.isEmpty else {
      center.updateClipboardRuntimeState(.skipped("No readable images found"))
      center.recordClipboardEvent(summary: snapshot.summary)
      return nil
    }

    center.updateClipboardRuntimeState(.matched(decision.policy.name))
    center.recordClipboardEvent(summary: snapshot.summary)
    return ClipboardAutomationDispatch(
      candidates: candidates,
      shouldOpenDashboardDebugging: decision.shouldOpenDashboardDebugging
    )
  }
}

struct ClipboardAutomationSnapshot: Equatable {
  let reason: ClipboardAutomationEvaluationReason
  let accessBehaviorDescription: String
  let declaredTypes: [String]
  let detectedContentType: String?
  let contentKinds: Set<AutomationClipboardContentKind>
  let containsSensitiveContent: Bool
  let sourceApplication: AutomationSourceApplication?

  var summary: String {
    let kinds = contentKinds.map(\.title).sorted().joined(separator: ", ")
    let appName = sourceApplication?.displayName ?? "Unknown app"
    return "\(kinds.isEmpty ? "Unknown" : kinds) from \(appName)"
  }

  var sourceMetadata: [DashboardOCRImageSourceMetadata] {
    var metadata = [
      DashboardOCRImageSourceMetadata(
        name: "Clipboard",
        detail: "NSPasteboard.general"
      )
    ]
    if let sourceApplication {
      metadata.append(
        DashboardOCRImageSourceMetadata(
          name: sourceApplication.displayName,
          detail: sourceApplication.bundleIdentifier
        )
      )
    }
    if let detectedContentType {
      metadata.append(
        DashboardOCRImageSourceMetadata(
          name: "Detected content type",
          detail: detectedContentType
        )
      )
    }
    return metadata
  }

  static func make(
    from pasteboard: NSPasteboard,
    reason: ClipboardAutomationEvaluationReason
  ) async -> Self {
    let declaredTypes = (pasteboard.types ?? []).map(\.rawValue)
    let detectedContentType = await detectedContentType(from: pasteboard)
    let detectedPatterns = await detectedPatterns(from: pasteboard)
    let contentKinds = contentKinds(
      declaredTypes: declaredTypes,
      detectedContentType: detectedContentType,
      detectedPatterns: detectedPatterns
    )
    return Self(
      reason: reason,
      accessBehaviorDescription: pasteboard.accessBehavior.automationDescription,
      declaredTypes: declaredTypes,
      detectedContentType: detectedContentType,
      contentKinds: contentKinds,
      containsSensitiveContent: containsSensitiveType(declaredTypes),
      sourceApplication: sourceApplication()
    )
  }

  private static func detectedContentType(from pasteboard: NSPasteboard) async -> String? {
    let keyPaths: Set<PartialKeyPath<NSPasteboard.DetectedMetadata>> = [\.contentType]
    guard
      let metadata = try? await pasteboard.detectedMetadata(for: keyPaths),
      let contentType = metadata.contentType
    else {
      return nil
    }
    return contentType.identifier
  }

  private static func detectedPatterns(
    from pasteboard: NSPasteboard
  ) async -> Set<PartialKeyPath<NSPasteboard.DetectedValues>> {
    let keyPaths: Set<PartialKeyPath<NSPasteboard.DetectedValues>> = [
      \.probableWebURL,
      \.probableWebSearch,
      \.number,
      \.links,
      \.emailAddresses,
    ]
    return (try? await pasteboard.detectedPatterns(for: keyPaths)) ?? []
  }

  private static func contentKinds(
    declaredTypes: [String],
    detectedContentType: String?,
    detectedPatterns: Set<PartialKeyPath<NSPasteboard.DetectedValues>>
  ) -> Set<AutomationClipboardContentKind> {
    var kinds = Set<AutomationClipboardContentKind>()
    let declaredContentTypes = declaredTypes.compactMap(UTType.init)
    if declaredContentTypes.contains(where: { $0.conforms(to: .image) })
      || detectedContentType.map({ UTType($0)?.conforms(to: .image) == true }) == true
    {
      kinds.insert(.image)
    }
    if declaredContentTypes.contains(where: { $0.conforms(to: .fileURL) })
      || detectedContentType != nil
    {
      kinds.insert(.file)
    }
    if declaredContentTypes.contains(where: { $0.conforms(to: .url) }) {
      kinds.insert(.url)
    }
    if declaredContentTypes.contains(where: { $0.conforms(to: .text) })
      || !detectedPatterns.isEmpty
    {
      kinds.insert(.text)
    }
    if detectedPatterns.contains(\NSPasteboard.DetectedValues.probableWebURL)
      || detectedPatterns.contains(\NSPasteboard.DetectedValues.links)
    {
      kinds.insert(.url)
    }
    if kinds.isEmpty {
      kinds.insert(.unknown)
    }
    return kinds
  }

  private static func containsSensitiveType(_ declaredTypes: [String]) -> Bool {
    let sensitiveTypes = Set([
      "org.nspasteboard.ConcealedType",
      "org.nspasteboard.TransientType",
      "com.agilebits.onepassword",
      "com.agilebits.onepassword.concealed",
    ])
    return declaredTypes.contains { sensitiveTypes.contains($0) }
  }

  private static func sourceApplication() -> AutomationSourceApplication? {
    guard let app = NSWorkspace.shared.frontmostApplication else {
      return nil
    }
    return AutomationSourceApplication(
      bundleIdentifier: app.bundleIdentifier,
      localizedName: app.localizedName,
      processIdentifier: app.processIdentifier
    )
  }
}

extension NSPasteboard.AccessBehavior {
  fileprivate var automationDescription: String {
    switch self {
    case .default:
      "default"
    case .ask:
      "ask"
    case .alwaysAllow:
      "alwaysAllow"
    case .alwaysDeny:
      "alwaysDeny"
    @unknown default:
      "unknown"
    }
  }
}

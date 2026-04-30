import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

@MainActor
@Observable
final class AcpPermissionAttentionState {
  private enum PreviewContextOverride: String {
    case foreground
    case hidden
  }

  private static let previewContextEnvironmentKey = "HARNESS_MONITOR_PREVIEW_ACP_ATTENTION_CONTEXT"

  var activeToast: AcpPermissionAttentionEvent?

  private let keyWindowObserver: KeyWindowObserver
  @ObservationIgnored private let notifications: HarnessMonitorUserNotificationController
  @ObservationIgnored private let previewContextOverride: PreviewContextOverride?
  @ObservationIgnored private var handledBatchIDs: Set<String> = []
  @ObservationIgnored private var deliveringBatchIDs: Set<String> = []
  @ObservationIgnored private var handledDecisionRequestTick = 0
  private var routeEventTick = 0
  private var lastRouteSource = "none"
  private var lastRouteDecisionID: String?
  private var lastRouteBatchID: String?

  init(
    keyWindowObserver: KeyWindowObserver,
    notifications: HarnessMonitorUserNotificationController
  ) {
    self.keyWindowObserver = keyWindowObserver
    self.notifications = notifications
    self.previewContextOverride = Self.resolvePreviewContextOverride()
  }

  var routingToken: String {
    [
      keyWindowObserver.snapshot.routingToken,
      "override=\(previewContextOverride?.rawValue ?? "live")",
    ].joined(separator: ",")
  }

  var routeStateText: String {
    [
      "source=\(lastRouteSource)",
      "decision=\(lastRouteDecisionID ?? "nil")",
      "batch=\(lastRouteBatchID ?? "nil")",
      "tick=\(routeEventTick)",
    ].joined(separator: " ")
  }

  func reconcile(store: HarnessMonitorStore) {
    let currentBatchIDs = Set(store.acpPermissionAttentionEvents.map(\.batchID))
    handledBatchIDs.formIntersection(currentBatchIDs)
    deliveringBatchIDs.formIntersection(currentBatchIDs)
    if let activeToast, !currentBatchIDs.contains(activeToast.batchID) {
      self.activeToast = nil
    }

    guard
      let nextAttention = store.acpPermissionAttentionEvents.first(where: {
        !handledBatchIDs.contains($0.batchID) && !deliveringBatchIDs.contains($0.batchID)
      })
    else {
      return
    }

    if prefersUserNotificationDelivery {
      activeToast = nil
      deliveringBatchIDs.insert(nextAttention.batchID)
      Task { @MainActor in
        defer { deliveringBatchIDs.remove(nextAttention.batchID) }
        if await notifications.deliverAcpPermissionRequest(nextAttention) {
          handledBatchIDs.insert(nextAttention.batchID)
        }
      }
      return
    }

    handledBatchIDs.insert(nextAttention.batchID)
    activeToast = nextAttention
  }

  func dismissToast() {
    if let activeToast {
      handledBatchIDs.insert(activeToast.batchID)
    }
    activeToast = nil
  }

  func showsToast(in windowID: String) -> Bool {
    guard activeToast != nil, !prefersUserNotificationDelivery else {
      return false
    }
    switch previewContextOverride {
    case .foreground:
      if keyWindowObserver.isKey(windowID: windowID) {
        return true
      }
      return keyWindowObserver.snapshot.keyWindowIdentifier == nil
        && windowID == HarnessMonitorWindowID.main
    case .hidden:
      return false
    case nil:
      return keyWindowObserver.isKey(windowID: windowID)
    }
  }

  func routeActiveToast(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) {
    guard let attention = activeToast else {
      return
    }
    routeAttention(
      attention,
      store: store,
      openWindow: openWindow
    )
  }

  func routeAttention(
    _ attention: AcpPermissionAttentionEvent,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) {
    guard canRouteToDecision(attention.decisionID, store: store) else {
      // Keep this path one-way for operators: unroutable attention is explicitly consumed
      // instead of silently looping as an always-clickable dead toast.
      handledBatchIDs.insert(attention.batchID)
      if activeToast?.batchID == attention.batchID {
        activeToast = nil
      }
      return
    }
    // Routing via the toast button is an explicit user decision to consume this batch.
    // Mark it handled before any window/focus transitions to prevent re-queuing.
    handledBatchIDs.insert(attention.batchID)
    publishRouteEvent(
      source: "toast",
      decisionID: attention.decisionID,
      batchID: attention.batchID
    )
    routeToDecision(
      decisionID: attention.decisionID,
      store: store,
      openWindow: openWindow
    )
    if activeToast?.batchID == attention.batchID {
      activeToast = nil
    }
  }

  func canRouteToDecision(_ decisionID: String, store: HarnessMonitorStore) -> Bool {
    store.supervisorOpenDecisions.contains(where: { $0.id == decisionID })
      || store.acpPermissionDecisionPayload(for: decisionID) != nil
  }

  func routeNotificationRequestIfNeeded(
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) {
    guard notifications.decisionRequestTick != handledDecisionRequestTick,
      let decisionID = notifications.decisionRequestedID
    else {
      return
    }
    guard canRouteToDecision(decisionID, store: store) else {
      // Consume stale/unroutable notification ticks so they do not spin forever.
      handledDecisionRequestTick = notifications.decisionRequestTick
      return
    }
    handledDecisionRequestTick = notifications.decisionRequestTick
    publishRouteEvent(
      source: "notification",
      decisionID: decisionID,
      batchID: nil
    )
    routeToDecision(
      decisionID: decisionID,
      store: store,
      openWindow: openWindow
    )
  }

  private var prefersUserNotificationDelivery: Bool {
    switch previewContextOverride {
    case .foreground:
      return false
    case .hidden:
      return true
    case nil:
      return keyWindowObserver.snapshot.prefersUserNotificationDelivery
    }
  }

  private func publishRouteEvent(source: String, decisionID: String, batchID: String?) {
    routeEventTick += 1
    lastRouteSource = source
    lastRouteDecisionID = decisionID
    lastRouteBatchID = batchID
  }

  private func routeToDecision(
    decisionID: String,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction,
    activatesApp: Bool = true
  ) {
    store.supervisorSelectedDecisionID = decisionID
    store.requestPrimaryDecisionActionFocus(decisionID: decisionID)
    if activatesApp {
      Self.activateHarnessMonitorApp()
    }
    openWindow(id: HarnessMonitorWindowID.decisions)
    Task { @MainActor in
      await Self.focusDecisionsWindow()
    }
  }

  private static func activateHarnessMonitorApp() {
    if #available(macOS 14.0, *) {
      NSApplication.shared.activate()
    } else {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

  private static func decisionsWindow() -> NSWindow? {
    NSApplication.shared.windows.first { window in
      let identifier = window.identifier?.rawValue ?? ""
      return KeyWindowObserver.matchesWindowID(
        identifier, expected: HarnessMonitorWindowID.decisions)
    }
  }

  private static func focusDecisionsWindow() async {
    for _ in 0..<20 {
      await Task.yield()
      guard let window = decisionsWindow() else {
        try? await Task.sleep(for: .milliseconds(25))
        continue
      }
      window.makeKeyAndOrderFront(nil)
      if window.isKeyWindow {
        return
      }
      try? await Task.sleep(for: .milliseconds(25))
      if window.isKeyWindow {
        return
      }
    }
  }

  private static func resolvePreviewContextOverride() -> PreviewContextOverride? {
    let environment = ProcessInfo.processInfo.environment
    guard
      let rawValue = environment[previewContextEnvironmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
      !rawValue.isEmpty
    else {
      return nil
    }
    switch rawValue {
    case "foreground", "active", "live":
      return .foreground
    case "hidden", "background", "minimized":
      return .hidden
    default:
      return nil
    }
  }
}

private struct AcpPermissionAttentionSceneModifier: ViewModifier {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let attentionState: AcpPermissionAttentionState
  let windowID: String

  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var observationKey: String {
    [
      store.pendingAcpPermissionBatches.map(\.batchId).joined(separator: "|"),
      "\(store.supervisorDecisionRefreshTick)",
      store.supervisorSelectedDecisionID ?? "nil",
      attentionState.routingToken,
    ].joined(separator: "||")
  }

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .topTrailing) {
        if attentionState.showsToast(in: windowID),
          let attention = attentionState.activeToast
        {
          AcpPermissionAttentionToastView(
            attention: attention,
            openDecisions: {
              attentionState.routeAttention(
                attention,
                store: store,
                openWindow: openWindow
              )
            },
            dismiss: attentionState.dismissToast
          )
          .padding(.top, HarnessMonitorTheme.spacingSM)
          .padding(.trailing, HarnessMonitorTheme.spacingLG)
          .allowsHitTesting(true)
          .zIndex(1_000)
          .transition(AcpPermissionAttentionMotionPolicy.transition(reduceMotion: reduceMotion))
        }
      }
      .animation(
        AcpPermissionAttentionMotionPolicy.animation(reduceMotion: reduceMotion),
        value: attentionState.activeToast?.batchID
      )
      .overlay {
        if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
          AccessibilityTextMarker(
            identifier: HarnessMonitorAccessibility.acpPermissionToastRouteState,
            text: attentionState.routeStateText
          )
        }
      }
      .task(id: observationKey) {
        attentionState.reconcile(store: store)
      }
      .task(id: notifications.decisionRequestTick) {
        attentionState.routeNotificationRequestIfNeeded(
          store: store,
          openWindow: openWindow
        )
      }
  }
}

enum AcpPermissionAttentionMotionPolicy {
  static func transition(reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
  }

  static func animation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.18)
  }

  static func markerText(reduceMotion: Bool) -> String {
    reduceMotion
      ? "transition=opacity animation=none" : "transition=move-top-opacity animation=spring"
  }
}

extension View {
  func acpPermissionAttentionScene(
    store: HarnessMonitorStore,
    notifications: HarnessMonitorUserNotificationController,
    attentionState: AcpPermissionAttentionState,
    windowID: String
  ) -> some View {
    modifier(
      AcpPermissionAttentionSceneModifier(
        store: store,
        notifications: notifications,
        attentionState: attentionState,
        windowID: windowID
      )
    )
  }
}

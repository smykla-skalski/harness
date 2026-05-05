import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

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
      store.presentingAcpPermissionBatch?.batchId ?? "nil",
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
          AcpPermissionAttentionToastView(attention: attention)
            .environment(
              \.acpToastOpenDecisions,
              { @MainActor in
                attentionState.routeAttention(
                  attention,
                  store: store,
                  openWindow: openWindow
                )
              }
            )
            .environment(\.acpToastDismiss, { @MainActor in attentionState.dismissToast() })
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
      .task(id: store.presentingAcpPermissionBatch?.batchId) {
        attentionState.routePresentedBatchIfNeeded(
          store: store,
          openWindow: openWindow
        )
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

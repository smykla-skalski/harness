import HarnessMonitorKit
import SwiftUI

public struct HarnessMonitorConfirmationDialogModifier: ViewModifier {
  public let store: HarnessMonitorStore
  public let shellUI: HarnessMonitorStore.ContentShellSlice

  public init(store: HarnessMonitorStore, shellUI: HarnessMonitorStore.ContentShellSlice) {
    self.store = store
    self.shellUI = shellUI
  }

  public func body(content: Content) -> some View {
    content
      .confirmationDialog(
        title,
        isPresented: Binding(
          get: { shellUI.pendingConfirmation != nil },
          set: { isPresented in
            if !isPresented {
              HarnessMonitorUITestTrace.record(
                component: "confirmation-dialog",
                event: "dismissed",
                details: [
                  "pending_confirmation": shellUI.pendingConfirmation?.uiTestTraceLabel ?? "nil"
                ]
              )
              store.cancelConfirmation()
            }
          }
        ),
        titleVisibility: .visible
      ) {
        if let pendingConfirmation = shellUI.pendingConfirmation {
          Button(confirmButtonTitle, role: .destructive) {
            HarnessMonitorUITestTrace.record(
              component: "confirmation-dialog",
              event: "confirm-tapped",
              details: ["pending_confirmation": pendingConfirmation.uiTestTraceLabel]
            )
            Task { await store.confirmPendingAction(pendingConfirmation) }
          }
        } else {
          EmptyView()
        }
        Button("Cancel", role: .cancel) {
          HarnessMonitorUITestTrace.record(
            component: "confirmation-dialog",
            event: "cancel-tapped",
            details: [
              "pending_confirmation": shellUI.pendingConfirmation?.uiTestTraceLabel ?? "nil"
            ]
          )
          store.cancelConfirmation()
        }
      } message: {
        if !message.isEmpty {
          Text(message)
        }
      }
  }

  private var title: String {
    switch shellUI.pendingConfirmation {
    case .endSession: "End Session?"
    case .removeSession: "Remove Session?"
    case .removeAgent: "Remove Agent?"
    case .interruptCodexRun: "Interrupt Whole Run?"
    case nil: ""
    }
  }

  private var confirmButtonTitle: String {
    switch shellUI.pendingConfirmation {
    case .endSession:
      "End Session Now"
    case .removeSession:
      "Remove Session Now"
    case .removeAgent:
      "Remove Agent Now"
    case .interruptCodexRun:
      "Interrupt Whole Run Now"
    case nil:
      ""
    }
  }

  private var message: String {
    switch shellUI.pendingConfirmation {
    case .endSession(let sessionID, _):
      """
      This ends \(store.confirmationSessionSubject(sessionID: sessionID)). \
      Active task work must already be closed.
      """
    case .removeSession(let sessionID, _):
      """
      This removes \(store.confirmationSessionSubject(sessionID: sessionID)) from Monitor \
      immediately. It disappears from the sidebar, open cockpit views, and cached data. \
      If the underlying session is still running, Monitor will stop showing it. Restoring \
      it requires a manual database operation.
      """
    case .removeAgent(let sessionID, let agentID, _):
      """
      This removes \(store.confirmationAgentSubject(sessionID: sessionID, agentID: agentID)) \
      and returns any active work to the queue.
      """
    case .interruptCodexRun(_, _, let runTitle):
      "This interrupts the active Codex run for \"\(runTitle)\". The current turn stops immediately."
    case nil:
      ""
    }
  }
}

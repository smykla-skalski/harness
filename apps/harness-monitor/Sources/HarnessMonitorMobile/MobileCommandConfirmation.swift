import HarnessMonitorCore
import SwiftUI

/// A pending command awaiting user confirmation before it is queued to the Mac.
///
/// Inline command buttons across the app (attention rows, review actions, agent
/// stop) route through this so a single tap cannot fire a high-risk or
/// destructive command without a confirmation step. Low-risk commands skip it.
struct PendingCommandConfirmation: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let confirmTitle: String
  let isDestructive: Bool
  let perform: () -> Void
}

extension View {
  /// Presents a confirmation dialog for the bound pending command, if any.
  func commandConfirmation(_ pending: Binding<PendingCommandConfirmation?>) -> some View {
    confirmationDialog(
      pending.wrappedValue?.title ?? "",
      isPresented: Binding(
        get: { pending.wrappedValue != nil },
        set: { if !$0 { pending.wrappedValue = nil } }
      ),
      titleVisibility: .visible,
      presenting: pending.wrappedValue
    ) { confirmation in
      Button(confirmation.confirmTitle, role: confirmation.isDestructive ? .destructive : nil) {
        confirmation.perform()
        pending.wrappedValue = nil
      }
      Button("Cancel", role: .cancel) {
        pending.wrappedValue = nil
      }
    } message: { confirmation in
      Text(confirmation.message)
    }
  }
}

/// Fires `perform` immediately for low-risk commands, otherwise stages a
/// confirmation through `pending`. Centralizes the risk-gating decision so
/// every call site treats merge/stop/approve consistently.
@MainActor
func confirmCommandIfNeeded(
  kind: MobileCommandKind,
  message: String,
  pending: Binding<PendingCommandConfirmation?>,
  perform: @escaping () -> Void
) {
  guard kind.risk != .low else {
    perform()
    return
  }
  pending.wrappedValue = PendingCommandConfirmation(
    title: kind.title,
    message: message,
    confirmTitle: kind.title,
    isDestructive: kind.risk == .destructive,
    perform: perform
  )
}

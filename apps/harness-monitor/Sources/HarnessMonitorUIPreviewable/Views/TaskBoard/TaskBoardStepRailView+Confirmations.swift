import HarnessMonitorKit
import SwiftUI

/// The authorize-before-mutating half of the manual-steps panel. Every board
/// mutation routes through here; only Pick skips it, being read-only.
extension TaskBoardStepRailView {
  var confirmationPresented: Binding<Bool> {
    Binding(
      get: { stepRailState.confirmation != nil },
      set: { if !$0 { stepRailState.confirmation = nil } }
    )
  }

  var confirmationTitle: String {
    switch stepRailState.confirmation {
    case .externalSync: "Run live external sync?"
    case .evaluate: "Run live task-board evaluation?"
    case .deliver: "Deliver and spawn this item?"
    case .complete: "Complete this board item?"
    case nil: "Confirm manual step"
    }
  }

  @ViewBuilder
  func confirmationActions(
    _ confirmation: TaskBoardStepRailState.Confirmation
  ) -> some View {
    switch confirmation {
    case .externalSync:
      Button("Sync Live", role: .destructive) {
        runConfirmation(confirmation)
      }
      .disabled(controlsDisabled)
    case .evaluate:
      Button("Evaluate Live", role: .destructive) {
        runConfirmation(confirmation)
      }
      .disabled(controlsDisabled)
    case .deliver(let itemID):
      Button("Deliver Live", role: .destructive) {
        runConfirmation(confirmation)
      }
      // Re-checks the item at press time: the flow may have moved on while the
      // dialog sat open.
      .disabled(controlsDisabled || deliveryItemID != itemID)
    case .complete:
      Button("Complete", role: .destructive) {
        runConfirmation(confirmation)
      }
      .disabled(controlsDisabled)
    }
    Button("Cancel", role: .cancel) {}
  }

  func runConfirmation(_ confirmation: TaskBoardStepRailState.Confirmation) {
    stepRailState.confirmation = nil
    switch confirmation {
    case .externalSync(let itemID): enqueueExternalSync(itemID: itemID)
    case .evaluate(let itemID): enqueueEvaluation(itemID: itemID)
    case .deliver(let itemID): enqueueDelivery(itemID: itemID)
    case .complete(let itemID): enqueueCompletion(itemID: itemID)
    }
  }

  func confirmationMessage(_ confirmation: TaskBoardStepRailState.Confirmation) -> String {
    let title =
      confirmation.itemID.flatMap { itemID in
        activeItem.flatMap { $0.id == itemID ? $0.title : nil }
      } ?? "the current item"
    return switch confirmation {
    case .externalSync:
      "This pulls external task sources and applies changes to the live board"
    case .evaluate:
      "This evaluates \(title) and applies any resulting board transition"
    case .deliver:
      "This reserves \(title) in step mode and starts its managed worker"
    case .complete:
      "This moves \(title) to Done"
    }
  }
}

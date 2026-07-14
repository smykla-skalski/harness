import HarnessMonitorKit
import Observation

@MainActor
@Observable
final class TaskBoardStepRailState {
  enum Confirmation: Identifiable {
    case externalSync
    case evaluate(step: Int)
    case deliver
    case complete

    var id: String {
      switch self {
      case .externalSync:
        "external-sync"
      case .evaluate(let step):
        "evaluate-\(step)"
      case .deliver:
        "deliver"
      case .complete:
        "complete"
      }
    }
  }

  var activeStep: Int?
  var completedSteps: Set<Int> = []
  var pickedSelection: TaskBoardDispatchSelection?
  var delivery: TaskBoardDispatchDelivery?
  var confirmation: Confirmation?
  var approvalRefreshGeneration: UInt64 = 0

  var isBusy: Bool { activeStep != nil }

  func begin(step: Int) -> Bool {
    guard activeStep == nil else { return false }
    activeStep = step
    return true
  }

  func finish(step: Int, succeeded: Bool) {
    guard activeStep == step else { return }
    if succeeded {
      completedSteps.insert(step)
    }
    activeStep = nil
  }

  func requestApprovalRefresh() {
    approvalRefreshGeneration &+= 1
  }

  func resetFlow() {
    pickedSelection = nil
    delivery = nil
    completedSteps.subtract([3, 4, 5, 6, 7, 8])
  }

  func reset() {
    activeStep = nil
    completedSteps = []
    pickedSelection = nil
    delivery = nil
    confirmation = nil
    approvalRefreshGeneration = 0
  }
}

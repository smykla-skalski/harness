import HarnessMonitorKit
import Observation

@MainActor
@Observable
final class TaskBoardLocalHostRoutingState {
  var projectTypes: [String]?
  var isLoading = false
  private var generation: UInt64 = 0

  func beginLoad() -> UInt64? {
    guard !isLoading else { return nil }
    generation &+= 1
    isLoading = true
    return generation
  }

  func finishLoad(projectTypes: [String], generation: UInt64) {
    guard self.generation == generation else { return }
    self.projectTypes = projectTypes
    isLoading = false
  }

  func finishLoadFailure(generation: UInt64) {
    guard self.generation == generation else { return }
    projectTypes = nil
    isLoading = false
  }

  func reset() {
    generation &+= 1
    projectTypes = nil
    isLoading = false
  }
}

extension TaskBoardOverviewView {
  func updateLocalHostRouting() {
    guard
      let store,
      store.contentUI.dashboard.connectionState == .online
    else {
      localHostRoutingStateValue.reset()
      return
    }
    let state = localHostRoutingStateValue
    guard let generation = state.beginLoad() else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading task-board host routing") {
        do {
          let projectTypes = try await store.taskBoardHostSnapshot().local.projectTypes
          await MainActor.run {
            state.finishLoad(projectTypes: projectTypes, generation: generation)
          }
        } catch {
          await MainActor.run {
            state.finishLoadFailure(generation: generation)
          }
        }
      }
    )
  }
}

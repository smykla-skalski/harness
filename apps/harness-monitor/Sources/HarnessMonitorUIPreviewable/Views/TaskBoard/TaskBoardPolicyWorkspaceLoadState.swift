import Observation

@MainActor
@Observable
final class TaskBoardPolicyWorkspaceLoadState {
  private(set) var isLoading = false
  private var generation: UInt64 = 0

  func beginLoad(hasWorkspace: Bool) -> UInt64? {
    guard !hasWorkspace, !isLoading else { return nil }
    generation &+= 1
    isLoading = true
    return generation
  }

  func finishLoad(generation: UInt64, apply: () -> Void) {
    guard self.generation == generation else { return }
    apply()
    isLoading = false
  }

  func invalidate() {
    generation &+= 1
    isLoading = false
  }
}

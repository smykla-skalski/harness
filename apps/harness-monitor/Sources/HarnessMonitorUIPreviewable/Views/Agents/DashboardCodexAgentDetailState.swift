import HarnessMonitorKit
import Observation

@MainActor
@Observable
final class DashboardCodexAgentDetailState {
  private(set) var detail: DashboardCodexAgentDetail?
  private(set) var isLoading = false
  private(set) var activeAction: String?
  var prompt = ""
  private var generation: UInt64 = 0

  init(detail: DashboardCodexAgentDetail? = nil) {
    self.detail = detail
  }

  func beginLoad() -> UInt64 {
    generation &+= 1
    isLoading = true
    return generation
  }

  func finishLoad(_ detail: DashboardCodexAgentDetail, generation expected: UInt64) {
    guard generation == expected else { return }
    self.detail = detail
    isLoading = false
  }

  func beginAction(_ title: String) -> Bool {
    guard activeAction == nil else { return false }
    activeAction = title
    return true
  }

  func finishAction(_ title: String) {
    guard activeAction == title else { return }
    activeAction = nil
  }
}

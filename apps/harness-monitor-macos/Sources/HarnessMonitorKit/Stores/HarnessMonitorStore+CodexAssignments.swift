import Foundation

extension HarnessMonitorStore {
  func assignCodexRuns(_ runs: [CodexRunSnapshot], selected: CodexRunSnapshot?) {
    if selectedCodexRuns != runs {
      selectedCodexRuns = runs
    }
    assignSelectedCodexRun(selected)
  }

  func assignSelectedCodexRun(_ run: CodexRunSnapshot?) {
    guard selectedCodexRun != run else {
      return
    }
    selectedCodexRun = run
  }
}

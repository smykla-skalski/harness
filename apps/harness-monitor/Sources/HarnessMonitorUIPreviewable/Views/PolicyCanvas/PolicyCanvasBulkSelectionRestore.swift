import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasBulkSelectionRestore: Equatable {
  let selection: PolicyCanvasSelection?
  let secondaries: Set<PolicyCanvasSelection>
}

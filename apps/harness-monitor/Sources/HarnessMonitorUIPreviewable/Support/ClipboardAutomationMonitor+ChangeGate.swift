import Foundation

extension ClipboardAutomationMonitor {
  static func shouldEvaluateObservedChange(
    observedChangeCount: Int,
    currentChangeCount: Int
  ) -> Bool {
    observedChangeCount == currentChangeCount
  }
}

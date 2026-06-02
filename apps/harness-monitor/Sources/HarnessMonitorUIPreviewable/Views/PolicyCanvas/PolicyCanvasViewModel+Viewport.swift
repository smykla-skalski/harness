import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasViewModel {
  /// Emit a human-readable status update to the host view. No-op when the host
  /// has not yet wired a `statusCallback`, which keeps unit-test paths quiet.
  func notifyStatus(_ status: String) {
    statusCallback?(status)
  }
}

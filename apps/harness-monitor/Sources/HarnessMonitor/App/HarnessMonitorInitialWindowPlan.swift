import HarnessMonitorKit
import HarnessMonitorUIPreviewable

struct HarnessMonitorInitialWindowPlan: Equatable {
  enum Destination: Equatable {
    case none
    case welcome
    case sessions([String])
  }

  let destination: Destination
  let shouldMarkBridgeFallbackComplete: Bool

  static func resolve(
    launchBehavior: HarnessMonitorLaunchBehavior,
    hasVisibleSessionWindows: Bool,
    restorePlan: HarnessMonitorStore.LaunchWindowRestorePlan = .init()
  ) -> Self {
    switch launchBehavior {
    case .alwaysOpenRecent:
      return Self(destination: .welcome, shouldMarkBridgeFallbackComplete: false)
    case .restoreSessionWindows:
      guard !hasVisibleSessionWindows else {
        return Self(destination: .none, shouldMarkBridgeFallbackComplete: false)
      }
      if restorePlan.sessionIDs.isEmpty {
        return Self(
          destination: .welcome,
          shouldMarkBridgeFallbackComplete: restorePlan.usedBridgeFallback
        )
      }
      return Self(
        destination: .sessions(restorePlan.sessionIDs),
        shouldMarkBridgeFallbackComplete: restorePlan.usedBridgeFallback
      )
    }
  }
}

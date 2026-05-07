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
    hasVisibleWindows: Bool,
    restorePlan: HarnessMonitorStore.LaunchWindowRestorePlan = .init()
  ) -> Self {
    guard !hasVisibleWindows else {
      return Self(destination: .none, shouldMarkBridgeFallbackComplete: false)
    }

    switch launchBehavior {
    case .alwaysOpenRecent:
      return Self(destination: .welcome, shouldMarkBridgeFallbackComplete: false)
    case .restoreSessionWindows:
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

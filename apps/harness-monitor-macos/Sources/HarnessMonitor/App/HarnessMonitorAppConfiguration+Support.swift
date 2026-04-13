import Foundation
import HarnessMonitorKit
import SwiftData

enum HarnessMonitorUITestWindowDefaults {
  private static let mainWindowWidthKey = "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH"
  private static let mainWindowHeightKey = "HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT"
  private static let standardMainWindowSize = CGSize(width: 1640, height: 980)

  static func mainWindowSize(environment: HarnessMonitorEnvironment, isUITesting: Bool) -> CGSize {
    guard isUITesting else {
      return standardMainWindowSize
    }

    let width = clampedDimension(
      rawValue: environment.values[mainWindowWidthKey],
      fallback: standardMainWindowSize.width
    )
    let height = clampedDimension(
      rawValue: environment.values[mainWindowHeightKey],
      fallback: standardMainWindowSize.height
    )

    return CGSize(width: width, height: height)
  }

  private static func clampedDimension(rawValue: String?, fallback: CGFloat) -> CGFloat {
    guard
      let rawValue,
      let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
      value.isFinite
    else {
      return fallback
    }

    return CGFloat(max(value, 640))
  }
}

struct HarnessMonitorPersistenceSetup {
  let container: ModelContainer?
  let error: String?

  static func resolve(
    environment: HarnessMonitorEnvironment,
    launchMode: HarnessMonitorLaunchMode
  ) -> Self {
    if environment.values["HARNESS_MONITOR_FORCE_PERSISTENCE_FAILURE"] == "1" {
      return Self(
        container: nil,
        error: persistenceUnavailableMessage(details: "Forced failure for testing.")
      )
    }

    do {
      let container =
        switch launchMode {
        case .live:
          try HarnessMonitorModelContainer.live(using: environment)
        case .preview, .empty:
          try HarnessMonitorModelContainer.preview()
        }

      return Self(container: container, error: nil)
    } catch {
      return Self(
        container: nil,
        error: persistenceUnavailableMessage(details: error.localizedDescription)
      )
    }
  }

  private static func persistenceUnavailableMessage(details: String) -> String {
    """
    Local persistence is unavailable. Harness Monitor will keep running, but bookmarks,
    notes, and search history are disabled. \(details)
    """
  }
}

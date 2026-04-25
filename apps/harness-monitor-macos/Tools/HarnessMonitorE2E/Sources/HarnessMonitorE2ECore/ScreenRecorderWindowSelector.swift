import Foundation

@available(macOS 15.0, *)
struct ScreenRecorderWindowCandidate: Equatable {
  let windowID: UInt32
  let title: String
  let bundleIdentifier: String?
  let isOnScreen: Bool
}

@available(macOS 15.0, *)
enum ScreenRecorderWindowSelector {
  private static let allowedBundleIdentifiers: Set<String> = [
    "io.harnessmonitor.app",
    "io.harnessmonitor.app.ui-testing",
  ]
  private static let mainWindowTitles: Set<String> = [
    "Harness Monitor",
    "Dashboard",
    "Session Cockpit",
    "Cockpit",
  ]

  static func captureWindow(
    from candidates: [ScreenRecorderWindowCandidate]
  ) throws -> ScreenRecorderWindowCandidate {
    guard let selectedWindow = try captureWindowIfAvailable(from: candidates) else {
      throw ScreenRecorder.Failure.monitorWindowNotFound
    }
    return selectedWindow
  }

  static func captureWindowIfAvailable(
    from candidates: [ScreenRecorderWindowCandidate]
  ) throws -> ScreenRecorderWindowCandidate? {
    let matchingCandidates = candidates.filter {
      $0.isOnScreen
        && allowedBundleIdentifiers.contains($0.bundleIdentifier ?? "")
        && mainWindowTitles.contains($0.title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    guard !matchingCandidates.isEmpty else { return nil }
    guard matchingCandidates.count == 1 else {
      throw ScreenRecorder.Failure.ambiguousMonitorWindows(matchingCandidates.count)
    }
    return matchingCandidates[0]
  }
}

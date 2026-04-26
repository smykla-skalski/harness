import Foundation

@available(macOS 15.0, *)
struct ScreenRecorderWindowCandidate: Equatable {
  let windowID: UInt32
  let title: String
  let bundleIdentifier: String?
  let processID: Int32
  let isOnScreen: Bool

  init(
    windowID: UInt32,
    title: String,
    bundleIdentifier: String?,
    processID: Int32 = 0,
    isOnScreen: Bool
  ) {
    self.windowID = windowID
    self.title = title
    self.bundleIdentifier = bundleIdentifier
    self.processID = processID
    self.isOnScreen = isOnScreen
  }
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
    from candidates: [ScreenRecorderWindowCandidate],
    requireProcessID: Int32? = nil
  ) throws -> ScreenRecorderWindowCandidate {
    guard
      let selectedWindow = try captureWindowIfAvailable(
        from: candidates, requireProcessID: requireProcessID)
    else {
      throw ScreenRecorder.Failure.monitorWindowNotFound
    }
    return selectedWindow
  }

  static func captureWindowIfAvailable(
    from candidates: [ScreenRecorderWindowCandidate],
    requireProcessID: Int32? = nil
  ) throws -> ScreenRecorderWindowCandidate? {
    let matchingCandidates = candidates.filter { candidate in
      guard candidate.isOnScreen else { return false }
      guard mainWindowTitles.contains(candidate.title.trimmingCharacters(in: .whitespacesAndNewlines))
      else { return false }
      if let requiredPID = requireProcessID {
        return candidate.processID == requiredPID
      }
      return allowedBundleIdentifiers.contains(candidate.bundleIdentifier ?? "")
    }

    guard !matchingCandidates.isEmpty else { return nil }
    guard matchingCandidates.count == 1 else {
      throw ScreenRecorder.Failure.ambiguousMonitorWindows(matchingCandidates.count)
    }
    return matchingCandidates[0]
  }
}

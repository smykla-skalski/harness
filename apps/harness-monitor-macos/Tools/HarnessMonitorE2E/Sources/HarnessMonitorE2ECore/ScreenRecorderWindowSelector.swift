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
  private static let preferredBundleIdentifiers: [String] = [
    "io.harnessmonitor.app",
    "io.harnessmonitor.app.ui-testing",
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
      let trimmedTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard mainWindowTitles.contains(trimmedTitle) else { return false }
      if let requiredPID = requireProcessID {
        return candidate.processID == requiredPID
      }
      return allowedBundleIdentifiers.contains(candidate.bundleIdentifier ?? "")
    }

    guard !matchingCandidates.isEmpty else { return nil }
    let prioritizedCandidates = matchingCandidates.sorted { lhs, rhs in
      priority(for: lhs) < priority(for: rhs)
    }
    guard let selectedWindow = prioritizedCandidates.first else {
      return nil
    }

    let selectedPriority = priority(for: selectedWindow)
    let samePriorityCount = prioritizedCandidates.filter {
      priority(for: $0) == selectedPriority
    }.count
    guard samePriorityCount == 1 else {
      throw ScreenRecorder.Failure.ambiguousMonitorWindows(samePriorityCount)
    }

    return selectedWindow
  }

  private static func priority(for candidate: ScreenRecorderWindowCandidate) -> Int {
    let bundleIdentifier = candidate.bundleIdentifier ?? ""
    if bundleIdentifier == preferredBundleIdentifiers[0] {
      return 0
    }
    if bundleIdentifier == preferredBundleIdentifiers[1] {
      return 1
    }
    return preferredBundleIdentifiers.count
  }
}

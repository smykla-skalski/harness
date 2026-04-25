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
    private static let mainWindowTitle = "Harness Monitor"

    static func captureWindow(
        from candidates: [ScreenRecorderWindowCandidate]
    ) throws -> ScreenRecorderWindowCandidate {
        let matchingCandidates = candidates.filter {
            $0.isOnScreen
                && allowedBundleIdentifiers.contains($0.bundleIdentifier ?? "")
                && $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == mainWindowTitle
        }

        guard !matchingCandidates.isEmpty else {
            throw ScreenRecorder.Failure.monitorWindowNotFound
        }
        guard matchingCandidates.count == 1 else {
            throw ScreenRecorder.Failure.ambiguousMonitorWindows(matchingCandidates.count)
        }
        return matchingCandidates[0]
    }
}

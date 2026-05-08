import Foundation
import Testing

@Suite("Session window unavailable recovery")
struct SessionWindowUnavailableViewTests {
  @Test("Stale session tokens render explicit recovery actions")
  func staleSessionTokensRenderExplicitRecoveryActions() throws {
    let unavailableSource = try sourceFile(named: "SessionWindowUnavailableView.swift")
    let windowSource = try sourceFile(named: "SessionWindowView.swift")
    let unavailableExtensionSource = try sourceFile(named: "SessionWindowView+Unavailable.swift")

    #expect(unavailableSource.contains("Session is no longer known to the daemon"))
    #expect(unavailableSource.contains("Label(\"Open Recents\""))
    #expect(unavailableSource.contains("Label(\"Close Window\""))
    #expect(unavailableExtensionSource.contains("SessionWindowUnavailableView("))
    #expect(windowSource.contains("if isUnknownSession"))
    #expect(unavailableExtensionSource.contains("didLoadSnapshot && snapshot == nil && summary == nil"))
    #expect(unavailableExtensionSource.contains("openWindow(id: HarnessMonitorWindowID.main)"))
  }

  private func sourceFile(named fileName: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Sessions"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}

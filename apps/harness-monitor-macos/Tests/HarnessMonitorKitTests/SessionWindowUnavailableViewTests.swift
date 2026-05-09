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
    #expect(unavailableExtensionSource.contains("openWindow(id: HarnessMonitorWindowID.openRecent)"))
  }

  @Test("Session windows request native accessibility focus after opening")
  func sessionWindowsRequestNativeAccessibilityFocusAfterOpening() throws {
    let windowSource = try sourceFile(named: "SessionWindowView.swift")

    #expect(windowSource.contains("@AccessibilityFocusState"))
    #expect(windowSource.contains("primaryContentAccessibilityFocused = true"))
    #expect(windowSource.contains(".accessibilityFocused($primaryContentAccessibilityFocused)"))
    #expect(windowSource.contains("requestPrimaryContentAccessibilityFocus()"))
    #expect(windowSource.contains("AccessibilityNotification.Announcement"))
    #expect(!windowSource.contains("NSAccessibility"))
    #expect(!windowSource.contains("NSWindow"))
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

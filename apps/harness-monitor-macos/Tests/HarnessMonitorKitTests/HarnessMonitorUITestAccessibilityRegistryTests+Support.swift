import Foundation

extension HarnessMonitorUITestAccessibilityRegistryTests {
  func sourceFile(named name: String) throws -> String {
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
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views"
      )
      .appendingPathComponent(name)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  func waitUntil(
    timeout: Duration = .seconds(1),
    interval: Duration = .milliseconds(10),
    _ predicate: @escaping @Sendable () async -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if await predicate() {
        return true
      }
      await Task.yield()
      try? await Task.sleep(for: interval)
    }
    return await predicate()
  }
}

@MainActor
final class AccessibilityRegistrySemanticPressProbe {
  private(set) var pressCount = 0

  func recordPress() {
    pressCount += 1
  }
}

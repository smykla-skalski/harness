import Foundation

extension HarnessMonitorUITestAccessibilityRegistryTests {
  func sourceFile(named name: String) throws -> String {
    try accessibilityRegistrySourceFile(named: name)
  }

  func uiTestSupportFile(named name: String) throws -> String {
    let fileURL =
      accessibilityRegistryRepoRoot()
      .appendingPathComponent(
        "apps/harness-monitor/Tests/HarnessMonitorUITestSupport"
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

extension HarnessMonitorUITestAccessibilityRegistryMoreTests {
  func sourceFile(named name: String) throws -> String {
    try accessibilityRegistrySourceFile(named: name)
  }

  func sourceFiles(pathContaining fragment: String) throws -> [String] {
    try accessibilityRegistrySourceFiles(pathContaining: fragment)
  }
}

private func accessibilityRegistrySourceFile(named name: String) throws -> String {
  let sourceRoots = accessibilityRegistrySourceRoots()

  for sourceRoot in sourceRoots {
    let fileURL = sourceRoot.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: fileURL.path) {
      return try String(contentsOf: fileURL, encoding: .utf8)
    }
  }

  let requestedBasename = URL(fileURLWithPath: name).lastPathComponent
  let candidateURLs =
    Array(
      Set(
        sourceRoots.flatMap { sourceRoot in
          FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
          )?
          .compactMap { element -> URL? in
            guard let url = element as? URL, url.lastPathComponent == requestedBasename else {
              return nil
            }
            return url
          } ?? []
        }
      )
    )

  if let matchedURL = candidateURLs.first(where: { $0.path.hasSuffix("/\(name)") }) {
    return try String(contentsOf: matchedURL, encoding: .utf8)
  }
  guard let resolvedURL = candidateURLs.only else {
    throw CocoaError(.fileNoSuchFile)
  }
  return try String(contentsOf: resolvedURL, encoding: .utf8)
}

private func accessibilityRegistrySourceFiles(pathContaining fragment: String) throws -> [String] {
  try accessibilityRegistryMatchingSourceURLs(pathContaining: fragment)
    .map { try String(contentsOf: $0, encoding: .utf8) }
}

private func accessibilityRegistrySourceRoots() -> [URL] {
  let repoRoot = accessibilityRegistryRepoRoot()
  return [
    repoRoot.appendingPathComponent(
      "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views"
    ),
    repoRoot.appendingPathComponent(
      "apps/harness-monitor/Sources/HarnessMonitor/App"
    ),
    repoRoot.appendingPathComponent(
      "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable"
    ),
  ]
}

private func accessibilityRegistryMatchingSourceURLs(pathContaining fragment: String) -> [URL] {
  let sourceRoots = accessibilityRegistrySourceRoots()
  let matches =
    sourceRoots.flatMap { sourceRoot in
      FileManager.default.enumerator(
        at: sourceRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )?
      .compactMap { element -> URL? in
        guard let url = element as? URL else { return nil }
        return url.path.contains(fragment) ? url : nil
      } ?? []
    }
  return Array(Set(matches)).sorted { $0.path < $1.path }
}

private func accessibilityRegistryRepoRoot() -> URL {
  let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  return
    testsDirectory
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

extension Array {
  fileprivate var only: Element? {
    count == 1 ? first : nil
  }
}

@MainActor
final class AccessibilityRegistrySemanticPressProbe {
  private(set) var pressCount = 0

  func recordPress() {
    pressCount += 1
  }
}

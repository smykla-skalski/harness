import XCTest

extension HarnessMonitorUITestCase {
  @discardableResult
  func configureIsolatedDataHome(
    for app: XCUIApplication,
    purpose: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Bool {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("HarnessMonitorUITests", isDirectory: true)
      .appendingPathComponent(
        storageDirectoryName(for: purpose),
        isDirectory: true
      )

    recordDiagnosticsTrace(
      event: "data-home.configure.begin",
      details: [
        "purpose": purpose,
        "root": root.path,
      ]
    )
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try seedObservabilityConfig(into: root)
      recordDiagnosticsTrace(
        event: "data-home.configure.success",
        details: [
          "purpose": purpose,
          "root": root.path,
        ]
      )
    } catch {
      recordDiagnosticsTrace(
        event: "data-home.configure.failed",
        details: [
          "purpose": purpose,
          "root": root.path,
          "error": String(describing: error),
        ]
      )
      XCTFail(
        "Failed to create isolated UI-test data home at \(root.path): \(error)",
        file: file,
        line: line
      )
      return false
    }

    app.launchEnvironment[Self.daemonDataHomeKey] = root.path
    addTeardownBlock { @MainActor in
      try? FileManager.default.removeItem(at: root)
    }
    return true
  }

  func openSettings(in app: XCUIApplication) {
    let preferencesRoot = element(
      in: app, identifier: HarnessMonitorUITestAccessibility.preferencesRoot)
    if preferencesRoot.exists {
      return
    }

    app.activate()
    app.typeKey(",", modifierFlags: .command)
  }

  private func storageDirectoryName(for purpose: String) -> String {
    let testName = storagePathComponent(name)
    let purposeName = storagePathComponent(purpose)
    return "\(testName)-\(purposeName)-\(UUID().uuidString)"
  }

  private func storagePathComponent(_ value: String) -> String {
    let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let component = value.unicodeScalars
      .map { allowedScalars.contains($0) ? String($0) : "-" }
      .joined()
      .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
    return component.isEmpty ? "launch" : component
  }

  private func seedObservabilityConfig(into root: URL) throws {
    let targetURL =
      root
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("observability", isDirectory: true)
      .appendingPathComponent("config.json")

    try FileManager.default.createDirectory(
      at: targetURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if FileManager.default.fileExists(atPath: targetURL.path) {
      try FileManager.default.removeItem(at: targetURL)
    }

    try defaultObservabilityConfigBody().write(
      to: targetURL,
      atomically: true,
      encoding: .utf8
    )
  }

  private func defaultObservabilityConfigBody() -> String {
    [
      "{",
      "  \"enabled\": true,",
      "  \"grpc_endpoint\": \"http://127.0.0.1:4317\",",
      "  \"http_endpoint\": \"http://127.0.0.1:4318\",",
      "  \"grafana_url\": \"http://127.0.0.1:3000\",",
      "  \"tempo_url\": \"http://127.0.0.1:3200\",",
      "  \"loki_url\": \"http://127.0.0.1:3100\",",
      "  \"prometheus_url\": \"http://127.0.0.1:9090\",",
      "  \"pyroscope_url\": \"http://127.0.0.1:4040\",",
      "  \"monitor_smoke_enabled\": false,",
      "  \"headers\": {}",
      "}",
    ].joined(separator: "\n")
  }
}

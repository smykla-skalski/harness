import Foundation
import XCTest

@MainActor
func recordStandaloneDiagnosticsSnapshot(
  in app: XCUIApplication,
  named name: String,
  artifactsDirectoryKey: String,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let screenshot = diagnosticsScreenshot(in: app)
  let hierarchy = app.debugDescription

  XCTContext.runActivity(named: name) { activity in
    let screenshotAttachment = XCTAttachment(screenshot: screenshot)
    screenshotAttachment.name = name
    screenshotAttachment.lifetime = .keepAlways
    activity.add(screenshotAttachment)

    let hierarchyAttachment = XCTAttachment(string: hierarchy)
    hierarchyAttachment.name = "\(name)-hierarchy"
    hierarchyAttachment.lifetime = .keepAlways
    activity.add(hierarchyAttachment)
  }

  let stem = sanitizedDiagnosticsComponent(name)
  let bundleStem = sanitizedDiagnosticsComponent(
    (Bundle.main.bundleIdentifier ?? "harnessmonitor-uitests")
      .replacingOccurrences(of: ".", with: "-")
  )
  let preservedStem = "\(bundleStem)-\(ProcessInfo.processInfo.processIdentifier)-\(stem)"
  let outputDirectories = [
    diagnosticsArtifactsDirectory(for: artifactsDirectoryKey),
    preservedDiagnosticsDirectoryURL(),
  ]
  .compactMap { $0 }
  guard !outputDirectories.isEmpty else {
    return
  }
  do {
    for directory in outputDirectories {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let fileStem =
        directory == diagnosticsArtifactsDirectory(for: artifactsDirectoryKey)
        ? stem
        : preservedStem
      let screenshotURL = directory.appendingPathComponent("\(fileStem).png")
      let hierarchyURL = directory.appendingPathComponent("\(fileStem).txt")
      try screenshot.pngRepresentation.write(to: screenshotURL)
      try hierarchy.write(
        to: hierarchyURL,
        atomically: true,
        encoding: .utf8
      )
    }
  } catch {
    appendDiagnosticsTrace(
      component: "ui-diagnostics",
      event: "snapshot.failed",
      testName: "standalone-diagnostics",
      details: [
        "name": name,
        "error": String(describing: error),
      ],
      artifactsDirectoryKey: artifactsDirectoryKey
    )
    XCTFail(
      "Failed to persist UI-test diagnostics snapshot \(name): \(error)",
      file: file,
      line: line
    )
  }
}

func diagnosticsArtifactsDirectory(for artifactsDirectoryKey: String) -> URL? {
  guard
    let rawPath = ProcessInfo.processInfo.environment[artifactsDirectoryKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
    rawPath.isEmpty == false
  else {
    return nil
  }
  return URL(fileURLWithPath: rawPath, isDirectory: true)
}

private func sanitizedDiagnosticsComponent(_ value: String) -> String {
  let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
  let component = value.unicodeScalars
    .map { allowedScalars.contains($0) ? String($0) : "-" }
    .joined()
    .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
  return component.isEmpty ? "snapshot" : component
}

@MainActor
private func diagnosticsScreenshot(in app: XCUIApplication) -> XCUIScreenshot {
  let chromeWindows = app.windows.containing(
    .any,
    identifier: HarnessMonitorUITestAccessibility.appChromeRoot
  )
  let window =
    chromeWindows.firstMatch.exists
    ? chromeWindows.firstMatch
    : app.windows.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "main-")
    ).firstMatch
  if window.exists {
    return window.screenshot()
  }
  return XCUIScreen.main.screenshot()
}

extension HarnessMonitorUITestCase {
  func recordDiagnosticsSnapshot(
    in app: XCUIApplication,
    named name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    recordDiagnosticsTrace(
      event: "snapshot.begin",
      app: app,
      details: ["name": name]
    )
    recordStandaloneDiagnosticsSnapshot(
      in: app,
      named: name,
      artifactsDirectoryKey: Self.artifactsDirectoryKey,
      file: file,
      line: line
    )
    recordDiagnosticsTrace(
      event: "snapshot.finish",
      app: app,
      details: ["name": name]
    )
  }

  func attachWindowScreenshot(
    in app: XCUIApplication,
    named name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let attachment = XCTAttachment(screenshot: diagnosticsScreenshot(in: app))
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func attachAppHierarchy(
    in app: XCUIApplication,
    named name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let attachment = XCTAttachment(string: app.debugDescription)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

}

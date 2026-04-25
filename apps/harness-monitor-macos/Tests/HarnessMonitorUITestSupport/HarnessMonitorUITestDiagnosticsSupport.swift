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

  guard let artifactsDirectory = diagnosticsArtifactsDirectory(for: artifactsDirectoryKey) else {
    return
  }

  let stem = sanitizedDiagnosticsComponent(name)
  do {
    try FileManager.default.createDirectory(
      at: artifactsDirectory,
      withIntermediateDirectories: true
    )
    try screenshot.pngRepresentation.write(
      to: artifactsDirectory.appendingPathComponent("\(stem).png")
    )
    try hierarchy.write(
      to: artifactsDirectory.appendingPathComponent("\(stem).txt"),
      atomically: true,
      encoding: .utf8
    )
  } catch {
    XCTFail(
      "Failed to persist UI-test diagnostics snapshot \(name): \(error)",
      file: file,
      line: line
    )
  }
}

private func diagnosticsArtifactsDirectory(for artifactsDirectoryKey: String) -> URL? {
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
  let mainWindow = app.windows.matching(identifier: "main").firstMatch
  let window = mainWindow.exists ? mainWindow : app.windows.firstMatch
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
    recordStandaloneDiagnosticsSnapshot(
      in: app,
      named: name,
      artifactsDirectoryKey: Self.artifactsDirectoryKey,
      file: file,
      line: line
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

import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task-board key file permission guard")
struct SettingsTaskBoardKeyFilePermissionGuardTests {
  @Test("0600 file passes through without prompting")
  func tightModePassesThrough() throws {
    let url = try writeKey(mode: 0o600)
    defer { try? FileManager.default.removeItem(at: url) }

    let decision = SettingsTaskBoardKeyFilePermissionGuard.evaluate(
      url: url,
      fileName: "SSH Key"
    )
    #expect(decision == .acceptAsIs)
  }

  @Test("0400 file passes through (strictly tighter than 0600)")
  func readOnlyModePassesThrough() throws {
    let url = try writeKey(mode: 0o400)
    defer { try? FileManager.default.removeItem(at: url) }

    let decision = SettingsTaskBoardKeyFilePermissionGuard.evaluate(
      url: url,
      fileName: "SSH Key"
    )
    #expect(decision == .acceptAsIs)
  }

  // Loose-permission file paths cannot be exercised without spinning up an
  // NSAlert (which the AppKit runtime refuses outside a main-event-loop test
  // host). Those flows are covered by the live verify checklist.

  private func writeKey(mode: Int) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-keyfile-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("id_test")
    try Data("key-material".utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: mode)],
      ofItemAtPath: url.path
    )
    return url
  }
}

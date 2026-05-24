import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task-board key file permission policy")
struct SettingsTaskBoardKeyFilePermissionPolicyTests {
  @Test("0600 passes through with no prompt")
  func tightModePassesThrough() {
    let decision = SettingsTaskBoardKeyFilePermissionPolicy.initialDecision(forPosixMode: 0o600)
    #expect(decision == .acceptAsIs)
  }

  @Test("0400 (read-only owner) passes through")
  func readOnlyModePassesThrough() {
    let decision = SettingsTaskBoardKeyFilePermissionPolicy.initialDecision(forPosixMode: 0o400)
    #expect(decision == .acceptAsIs)
  }

  @Test("0644 (any other-readable bit) triggers prompt")
  func otherReadableTriggersPrompt() {
    let decision = SettingsTaskBoardKeyFilePermissionPolicy.initialDecision(forPosixMode: 0o644)
    #expect(decision == .needsPrompt(currentMode: 0o644))
  }

  @Test("0660 (group-rw) triggers prompt")
  func groupReadableTriggersPrompt() {
    let decision = SettingsTaskBoardKeyFilePermissionPolicy.initialDecision(forPosixMode: 0o660)
    #expect(decision == .needsPrompt(currentMode: 0o660))
  }

  @Test("0700 (owner-exec) triggers prompt — private keys must not be executable")
  func ownerExecTriggersPrompt() {
    let decision = SettingsTaskBoardKeyFilePermissionPolicy.initialDecision(forPosixMode: 0o700)
    #expect(decision == .needsPrompt(currentMode: 0o700))
  }

  @Test(".tighten + successful chmod -> .tightened")
  func tightenSucceeds() {
    let decision = SettingsTaskBoardKeyFilePermissionPolicy.resolve(choice: .tighten) {
      true
    }
    #expect(decision == .tightened)
  }

  @Test(".tighten + chmod failure falls back to .acceptAsIs")
  func tightenFails() {
    let decision = SettingsTaskBoardKeyFilePermissionPolicy.resolve(choice: .tighten) {
      false
    }
    #expect(decision == .acceptAsIs)
  }

  @Test(".acceptAsIs short-circuits without calling tighten")
  func acceptAsIsSkipsTighten() {
    var tightenCalled = false
    let decision = SettingsTaskBoardKeyFilePermissionPolicy.resolve(choice: .acceptAsIs) {
      tightenCalled = true
      return true
    }
    #expect(decision == .acceptAsIs)
    #expect(tightenCalled == false)
  }

  @Test(".cancel short-circuits without calling tighten")
  func cancelSkipsTighten() {
    var tightenCalled = false
    let decision = SettingsTaskBoardKeyFilePermissionPolicy.resolve(choice: .cancel) {
      tightenCalled = true
      return true
    }
    #expect(decision == .cancelled)
    #expect(tightenCalled == false)
  }

  @Test("Octal formatter zero-pads to four digits")
  func octalFormatter() {
    #expect(SettingsTaskBoardKeyFilePermissionPolicy.octal(0o644) == "0644")
    #expect(SettingsTaskBoardKeyFilePermissionPolicy.octal(0o600) == "0600")
    #expect(SettingsTaskBoardKeyFilePermissionPolicy.octal(0o4) == "0004")
  }
}

@MainActor
@Suite("Task-board key file chmod helpers")
struct SettingsTaskBoardKeyFileChmodTests {
  @Test("currentMode reads the on-disk permission bits")
  func currentModeReadsDiskBits() throws {
    let url = try writeKey(mode: 0o644)
    defer { try? FileManager.default.removeItem(at: url) }
    let mode = try #require(SettingsTaskBoardKeyFileChmod.currentMode(at: url))
    #expect(mode & 0o7777 == 0o644)
  }

  @Test("tighten chmods the file to 0o600")
  func tightenAppliesMode() throws {
    let url = try writeKey(mode: 0o644)
    defer { try? FileManager.default.removeItem(at: url) }
    let error = SettingsTaskBoardKeyFileChmod.tighten(url)
    #expect(error == nil)
    let after = try #require(SettingsTaskBoardKeyFileChmod.currentMode(at: url))
    #expect(after & 0o7777 == 0o600)
  }

  @Test("tighten returns an error when the file does not exist")
  func tightenSurfacesError() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-keyfile-missing-\(UUID().uuidString)")
    let error = SettingsTaskBoardKeyFileChmod.tighten(missing)
    #expect(error != nil)
  }

  @Test("Guard accepts an already-tight file without UI")
  func guardAcceptsTightFile() throws {
    let url = try writeKey(mode: 0o600)
    defer { try? FileManager.default.removeItem(at: url) }
    let decision = SettingsTaskBoardKeyFilePermissionGuard.evaluate(
      url: url,
      fileName: "SSH Key"
    )
    #expect(decision == .acceptAsIs)
  }

  // The loose-mode evaluate path is covered by the policy-layer tests above
  // (initialDecision + resolve) since the AppKit alert can't run in the test
  // host. The guard's presenter is a thin wrapper that calls into that policy.

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

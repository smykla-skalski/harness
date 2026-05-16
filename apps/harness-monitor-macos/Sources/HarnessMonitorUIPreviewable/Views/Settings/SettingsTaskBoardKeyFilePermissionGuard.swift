import AppKit
import Foundation

enum SettingsTaskBoardKeyFilePermissionDecision {
  case acceptAsIs
  case tightened
  case cancelled
}

enum SettingsTaskBoardKeyFilePermissionGuard {
  /// Inspect the POSIX permission bits of a freshly-picked private-key file.
  /// If anything beyond the owner read/write bits (0o600) is set, prompt the
  /// user to tighten the file to 0o600 or accept the loose permissions. Files
  /// that are already 0o600 or stricter pass through without any UI.
  ///
  /// Returns `.tightened` when the file has been chmod-ed to 0o600,
  /// `.acceptAsIs` when the user kept the loose permissions or the file was
  /// already strict, `.cancelled` when the user backed out of the picker.
  @MainActor
  static func evaluate(url: URL, fileName: String) -> SettingsTaskBoardKeyFilePermissionDecision {
    guard let mode = posixPermissions(at: url.path) else { return .acceptAsIs }
    guard mode & 0o077 != 0 || mode & 0o100 != 0 else { return .acceptAsIs }
    return presentTightenAlert(url: url, fileName: fileName, currentMode: mode)
  }

  private static func posixPermissions(at path: String) -> Int? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
    return (attrs[.posixPermissions] as? NSNumber)?.intValue
  }

  @MainActor
  private static func presentTightenAlert(
    url: URL,
    fileName: String,
    currentMode: Int
  ) -> SettingsTaskBoardKeyFilePermissionDecision {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Tighten permissions on \(fileName)?"
    alert.informativeText = """
      \(url.lastPathComponent) is mode \(octal(currentMode)). Private keys should be \
      mode 0600 (owner read/write only). Loose permissions let other users on this \
      Mac read the key.
      """
    alert.addButton(withTitle: "Set to 0600")
    alert.addButton(withTitle: "Use As Is")
    alert.addButton(withTitle: "Cancel")
    let response = alert.runModal()
    switch response {
    case .alertFirstButtonReturn:
      return tighten(url: url) ? .tightened : .acceptAsIs
    case .alertSecondButtonReturn:
      return .acceptAsIs
    default:
      return .cancelled
    }
  }

  @MainActor
  private static func tighten(url: URL) -> Bool {
    do {
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: url.path
      )
      return true
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = "Could not change permissions"
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return false
    }
  }

  private static func octal(_ mode: Int) -> String {
    String(format: "%04o", mode & 0o7777)
  }
}

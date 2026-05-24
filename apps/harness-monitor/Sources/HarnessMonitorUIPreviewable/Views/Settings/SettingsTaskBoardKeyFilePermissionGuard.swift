import AppKit
import Foundation

enum SettingsTaskBoardKeyFilePermissionDecision: Equatable {
  case acceptAsIs
  case tightened
  case cancelled
}

/// Pure policy layer for the chmod-0600 guard. The functions here never touch
/// AppKit, so every branch can be exercised under unit tests without spinning
/// up an event loop. `SettingsTaskBoardKeyFilePermissionGuard.evaluate` is the
/// AppKit-aware presenter that consumes this policy.
enum SettingsTaskBoardKeyFilePermissionPolicy {
  enum InitialDecision: Equatable {
    /// Mode is 0o600 or stricter; no prompt required.
    case acceptAsIs
    /// Mode has bits beyond owner read/write set; prompt the user.
    case needsPrompt(currentMode: Int)
  }

  enum UserChoice: Equatable {
    case tighten
    case acceptAsIs
    case cancel
  }

  /// Whether a freshly-picked private-key file needs the chmod-0600 prompt.
  /// Any group/other bit or the owner-execute bit triggers it.
  static func initialDecision(forPosixMode mode: Int) -> InitialDecision {
    if mode & 0o077 != 0 || mode & 0o100 != 0 {
      return .needsPrompt(currentMode: mode)
    }
    return .acceptAsIs
  }

  /// Resolve the user's choice into the final decision. The `tighten` closure
  /// returns `true` when the chmod succeeded and `false` when it failed; on
  /// failure we land at `.acceptAsIs` so the user can decide how to proceed
  /// rather than being trapped.
  static func resolve(
    choice: UserChoice,
    tighten: () -> Bool
  ) -> SettingsTaskBoardKeyFilePermissionDecision {
    switch choice {
    case .tighten:
      return tighten() ? .tightened : .acceptAsIs
    case .acceptAsIs:
      return .acceptAsIs
    case .cancel:
      return .cancelled
    }
  }

  /// Octal text the prompt copy uses to describe the current mode.
  static func octal(_ mode: Int) -> String {
    String(format: "%04o", mode & 0o7777)
  }
}

enum SettingsTaskBoardKeyFileChmod {
  /// Read POSIX permission bits from the URL's path. Returns `nil` when the
  /// attribute is unavailable; the caller treats that as `acceptAsIs` to avoid
  /// blocking the user on an inscrutable filesystem.
  static func currentMode(at url: URL) -> Int? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return nil
    }
    return (attrs[.posixPermissions] as? NSNumber)?.intValue
  }

  /// Apply mode 0o600 to the file at the URL. Returns the underlying error so
  /// the caller can surface it; on success returns nil.
  static func tighten(_ url: URL) -> Error? {
    do {
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: url.path
      )
      return nil
    } catch {
      return error
    }
  }
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
    guard let mode = SettingsTaskBoardKeyFileChmod.currentMode(at: url) else {
      return .acceptAsIs
    }
    switch SettingsTaskBoardKeyFilePermissionPolicy.initialDecision(forPosixMode: mode) {
    case .acceptAsIs:
      return .acceptAsIs
    case .needsPrompt(let currentMode):
      let choice = presentTightenAlert(
        url: url,
        fileName: fileName,
        currentMode: currentMode
      )
      return SettingsTaskBoardKeyFilePermissionPolicy.resolve(choice: choice) {
        tightenOrAlert(url: url)
      }
    }
  }

  @MainActor
  private static func presentTightenAlert(
    url: URL,
    fileName: String,
    currentMode: Int
  ) -> SettingsTaskBoardKeyFilePermissionPolicy.UserChoice {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Tighten permissions on \(fileName)?"
    alert.informativeText = """
      \(url.lastPathComponent) is mode \
      \(SettingsTaskBoardKeyFilePermissionPolicy.octal(currentMode)). Private keys \
      should be mode 0600 (owner read/write only). Loose permissions let other \
      users on this Mac read the key.
      """
    alert.addButton(withTitle: "Set to 0600")
    alert.addButton(withTitle: "Use As Is")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .tighten
    case .alertSecondButtonReturn: return .acceptAsIs
    default: return .cancel
    }
  }

  @MainActor
  private static func tightenOrAlert(url: URL) -> Bool {
    if let error = SettingsTaskBoardKeyFileChmod.tighten(url) {
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = "Could not change permissions"
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return false
    }
    return true
  }
}

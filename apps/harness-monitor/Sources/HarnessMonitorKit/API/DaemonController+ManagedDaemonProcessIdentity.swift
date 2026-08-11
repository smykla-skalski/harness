import Foundation
import Security

extension DaemonController {
  public static let defaultManagedProcessValidator: ManagedProcessValidator = { pid in
    var code: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    guard
      SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
      let code,
      SecCodeCheckValidity(code, [], nil) == errSecSuccess
    else {
      return false
    }

    var staticCode: SecStaticCode?
    guard
      SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
      let staticCode
    else {
      return false
    }
    var signingInformation: CFDictionary?
    guard
      SecCodeCopySigningInformation(staticCode, [], &signingInformation) == errSecSuccess,
      let information = signingInformation as? [String: Any],
      information[kSecCodeInfoTeamIdentifier as String] as? String
        == "Q498EB36N4",
      let identifier = information[kSecCodeInfoIdentifier as String] as? String
    else {
      return false
    }
    return isTrustedManagedHelperIdentifier(identifier)
  }

  static func isTrustedManagedHelperIdentifier(_ identifier: String) -> Bool {
    let currentBase = HarnessMonitorRuntimeLane.launchAgentBaseLabel
    let legacyBase = HarnessMonitorRuntimeLane.legacyLaunchAgentBaseLabel
    return identifier == currentBase
      || identifier.hasPrefix("\(currentBase)-")
      || identifier == legacyBase
      || identifier.hasPrefix("\(legacyBase)-")
      || [
        "Q498EB36N4.io.harnessmonitor.daemon",
        "io.harnessmonitor.daemon",
      ].contains(identifier)
  }

  func validatedManagedDaemonFallbackPID(_ manifest: DaemonManifest) throws -> Int32 {
    guard manifest.sandboxed, manifest.pid > 0, manifest.pid <= Int(Int32.max) else {
      throw DaemonControlError.invalidManifest(
        "managed daemon fallback requires a sandboxed process"
      )
    }
    let pid = Int32(manifest.pid)
    guard case .alive(let runningPath?) = processLiveness(pid) else {
      throw DaemonControlError.commandFailed(
        "managed daemon process identity is unavailable"
      )
    }
    let executableURL = URL(fileURLWithPath: runningPath).resolvingSymlinksInPath()
    guard Self.isTrustedManagedHelperExecutablePath(executableURL.path) else {
      throw DaemonControlError.invalidManifest(
        "managed daemon process does not use the bundled helper path"
      )
    }
    if let stampedPath = manifest.binaryStamp?.helperPath {
      let stampedURL = URL(fileURLWithPath: stampedPath).resolvingSymlinksInPath()
      guard stampedURL == executableURL else {
        throw DaemonControlError.invalidManifest(
          "managed daemon process path does not match its published identity"
        )
      }
    }
    guard managedDaemonProcessIdentityValidator(pid) else {
      throw DaemonControlError.invalidManifest(
        "managed daemon process signature is not trusted"
      )
    }
    return pid
  }

  static func isTrustedManagedHelperExecutablePath(_ path: String) -> Bool {
    path.hasSuffix("/Contents/Helpers/harness-daemon")
      || path.hasSuffix("/Contents/Resources/harness-daemon")
  }
}

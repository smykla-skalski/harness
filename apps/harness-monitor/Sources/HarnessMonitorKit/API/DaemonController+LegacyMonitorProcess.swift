import AppKit
import Foundation
import Security

final class LegacyMonitorProcessScanCache: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var cachedValue: Bool?

  func value(using scan: @Sendable () async -> Bool) async -> Bool {
    while true {
      let snapshot = lock.withLock { (generation, cachedValue) }
      if let cachedValue = snapshot.1 {
        return cachedValue
      }
      let value = await scan()
      let stored = lock.withLock { () -> Bool in
        guard generation == snapshot.0 else { return false }
        cachedValue = value
        return true
      }
      if stored {
        return value
      }
    }
  }

  func invalidate() {
    lock.withLock {
      generation &+= 1
      cachedValue = nil
    }
  }
}

extension DaemonController {
  public func invalidateLegacyMonitorProcessScan() {
    legacyMonitorProcessScanCache.invalidate()
  }

  static func defaultLegacyMonitorProcessIsRunning() async -> Bool {
    let processIDs: [pid_t] = await MainActor.run {
      let currentPID = ProcessInfo.processInfo.processIdentifier
      return NSWorkspace.shared.runningApplications.compactMap { application in
        guard
          application.processIdentifier != currentPID,
          application.isTerminated == false,
          application.bundleIdentifier?.hasPrefix("io.harnessmonitor.app") == true
        else {
          return nil
        }
        return application.processIdentifier
      }
    }
    return await Task.detached(priority: .utility) {
      processIDs.contains { processID in
        legacyMonitorLabelNeedsContainment(
          managedLaunchAgentLabel(forProcess: processID)
        )
      }
    }.value
  }

  static func legacyMonitorLabelNeedsContainment(_ label: String?) -> Bool {
    let lanePrefix = "\(HarnessMonitorRuntimeLane.launchAgentBaseLabel)-"
    guard let label else { return true }
    return !label.hasPrefix(lanePrefix) || label.count == lanePrefix.count
  }

  private static func managedLaunchAgentLabel(forProcess processID: pid_t) -> String? {
    var dynamicCode: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: processID)] as CFDictionary
    guard
      SecCodeCopyGuestWithAttributes(nil, attributes, [], &dynamicCode) == errSecSuccess,
      let dynamicCode,
      SecCodeCheckValidity(dynamicCode, [], nil) == errSecSuccess
    else {
      return nil
    }

    var staticCode: SecStaticCode?

    guard
      SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
      let staticCode
    else {
      return nil
    }
    var signingInformation: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard
      SecCodeCopySigningInformation(staticCode, flags, &signingInformation) == errSecSuccess,
      let information = signingInformation as? [String: Any],
      let plist = information[kSecCodeInfoPList as String] as? [String: Any]
    else {
      return nil
    }
    return plist["HarnessMonitorManagedLaunchAgentLabel"] as? String
  }
}

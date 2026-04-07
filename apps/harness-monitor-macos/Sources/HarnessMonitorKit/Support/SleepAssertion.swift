import Foundation
import IOKit
import IOKit.pwr_mgt

@MainActor
final class SleepAssertion {
  private var assertionID: IOPMAssertionID = 0

  func update(hasActiveSessions: Bool) {
    if hasActiveSessions {
      acquire()
    } else {
      release()
    }
  }

  private func acquire() {
    guard assertionID == 0 else { return }
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      "Harness sessions active" as CFString,
      &assertionID
    )
    if result == kIOReturnSuccess {
      HarnessMonitorLogger.sleep.info("Sleep prevention acquired")
    } else {
      HarnessMonitorLogger.sleep.warning("Failed to acquire sleep assertion: \(result)")
    }
  }

  func release() {
    guard assertionID != 0 else { return }
    IOPMAssertionRelease(assertionID)
    assertionID = 0
    HarnessMonitorLogger.sleep.info("Sleep prevention released")
  }

  deinit {
    if assertionID != 0 {
      IOPMAssertionRelease(assertionID)
    }
  }
}

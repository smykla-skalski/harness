import HarnessMonitorUIPreviewable
import XCTest

import HarnessMonitorPolicyCanvas

final class PolicyCanvasThemeDefaultsRegistrationTests: XCTestCase {
  func testStartupDefaultsRegisterUseAppThemeForPolicyCanvasThemeMode() {
    XCTAssertEqual(
      HarnessMonitorStartupRegistrationDefaults.values()[PolicyCanvasThemeDefaults.modeKey]
        as? String,
      PolicyCanvasThemeMode.defaultValue.rawValue
    )
  }
}

import HarnessMonitorPolicyCanvas
import HarnessMonitorUIPreviewable
import XCTest

final class PolicyCanvasThemeDefaultsRegistrationTests: XCTestCase {
  func testStartupDefaultsRegisterUseAppThemeForPolicyCanvasThemeMode() {
    XCTAssertEqual(
      HarnessMonitorStartupRegistrationDefaults.values()[
        HarnessMonitorUIPreviewable.PolicyCanvasThemeDefaults.modeKey
      ] as? String,
      HarnessMonitorUIPreviewable.PolicyCanvasThemeMode.defaultValue.rawValue
    )
  }
}

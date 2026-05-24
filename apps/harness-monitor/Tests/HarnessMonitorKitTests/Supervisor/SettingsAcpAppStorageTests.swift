import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SettingsAcpAppStorageTests: XCTestCase {
  func test_effectiveValueUsesStoredValueWhenEnvironmentMissing() {
    let userDefaults = makeUserDefaults()
    userDefaults.set(true, forKey: HarnessMonitorAcpCatalogSettings.appStorageKey)

    let resolved = HarnessMonitorAcpCatalogSettings.effectiveValue(
      userDefaults: userDefaults,
      environment: [:]
    )

    XCTAssertTrue(resolved)
  }

  func test_effectiveValueEnvironmentOverridesStoredValue() {
    let userDefaults = makeUserDefaults()
    userDefaults.set(false, forKey: HarnessMonitorAcpCatalogSettings.appStorageKey)

    XCTAssertTrue(
      HarnessMonitorAcpCatalogSettings.effectiveValue(
        userDefaults: userDefaults,
        environment: [HarnessMonitorAcpCatalogSettings.environmentKey: "1"]
      )
    )
    XCTAssertFalse(
      HarnessMonitorAcpCatalogSettings.effectiveValue(
        userDefaults: userDefaults,
        environment: [HarnessMonitorAcpCatalogSettings.environmentKey: "false"]
      )
    )
  }

  func test_effectiveValueIgnoresInvalidEnvironmentValue() {
    let userDefaults = makeUserDefaults()
    userDefaults.set(true, forKey: HarnessMonitorAcpCatalogSettings.appStorageKey)

    let resolved = HarnessMonitorAcpCatalogSettings.effectiveValue(
      userDefaults: userDefaults,
      environment: [HarnessMonitorAcpCatalogSettings.environmentKey: "banana"]
    )

    XCTAssertTrue(resolved)
  }

  func test_viewModelRespectsEnvironmentOverride() {
    let userDefaults = makeUserDefaults()
    userDefaults.set(false, forKey: HarnessMonitorAcpCatalogSettings.appStorageKey)
    let viewModel = SettingsSupervisorNotificationsViewModel(
      userDefaults: userDefaults,
      environment: [HarnessMonitorAcpCatalogSettings.environmentKey: "true"]
    )

    XCTAssertTrue(viewModel.acpCatalogEnabled)
    XCTAssertTrue(viewModel.acpCatalogForcedByEnvironment)

    viewModel.setAcpCatalogEnabled(false)

    XCTAssertTrue(viewModel.acpCatalogEnabled)
    XCTAssertEqual(
      userDefaults.object(forKey: HarnessMonitorAcpCatalogSettings.appStorageKey) as? Bool,
      false
    )
  }

  private func makeUserDefaults() -> UserDefaults {
    let suiteName = "SettingsAcpAppStorageTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    addTeardownBlock {
      userDefaults.removePersistentDomain(forName: suiteName)
    }
    return userDefaults
  }
}

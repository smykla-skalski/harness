import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class PreferencesAcpAppStorageTests: XCTestCase {
  func test_effectiveValueUsesStoredValueWhenEnvironmentMissing() {
    let userDefaults = makeUserDefaults()
    userDefaults.set(true, forKey: HarnessMonitorAcpCatalogPreferences.appStorageKey)

    let resolved = HarnessMonitorAcpCatalogPreferences.effectiveValue(
      userDefaults: userDefaults,
      environment: [:]
    )

    XCTAssertTrue(resolved)
  }

  func test_effectiveValueEnvironmentOverridesStoredValue() {
    let userDefaults = makeUserDefaults()
    userDefaults.set(false, forKey: HarnessMonitorAcpCatalogPreferences.appStorageKey)

    XCTAssertTrue(
      HarnessMonitorAcpCatalogPreferences.effectiveValue(
        userDefaults: userDefaults,
        environment: [HarnessMonitorAcpCatalogPreferences.environmentKey: "1"]
      )
    )
    XCTAssertFalse(
      HarnessMonitorAcpCatalogPreferences.effectiveValue(
        userDefaults: userDefaults,
        environment: [HarnessMonitorAcpCatalogPreferences.environmentKey: "false"]
      )
    )
  }

  func test_effectiveValueIgnoresInvalidEnvironmentValue() {
    let userDefaults = makeUserDefaults()
    userDefaults.set(true, forKey: HarnessMonitorAcpCatalogPreferences.appStorageKey)

    let resolved = HarnessMonitorAcpCatalogPreferences.effectiveValue(
      userDefaults: userDefaults,
      environment: [HarnessMonitorAcpCatalogPreferences.environmentKey: "banana"]
    )

    XCTAssertTrue(resolved)
  }

  func test_viewModelRespectsEnvironmentOverride() {
    let userDefaults = makeUserDefaults()
    userDefaults.set(false, forKey: HarnessMonitorAcpCatalogPreferences.appStorageKey)
    let viewModel = PreferencesSupervisorNotificationsViewModel(
      userDefaults: userDefaults,
      environment: [HarnessMonitorAcpCatalogPreferences.environmentKey: "true"]
    )

    XCTAssertTrue(viewModel.acpCatalogEnabled)
    XCTAssertTrue(viewModel.acpCatalogForcedByEnvironment)

    viewModel.setAcpCatalogEnabled(false)

    XCTAssertTrue(viewModel.acpCatalogEnabled)
    XCTAssertEqual(
      userDefaults.object(forKey: HarnessMonitorAcpCatalogPreferences.appStorageKey) as? Bool,
      false
    )
  }

  private func makeUserDefaults() -> UserDefaults {
    let suiteName = "PreferencesAcpAppStorageTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    addTeardownBlock {
      userDefaults.removePersistentDomain(forName: suiteName)
    }
    return userDefaults
  }
}

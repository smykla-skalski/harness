import CloudKit
import Foundation
import HarnessMonitorCloudMirror
import XCTest

final class MobileCloudMirrorSubscriptionServiceTests: XCTestCase {
  func testRegisterSkipsWhenCurrentAccountAlreadyRecorded() async {
    let registrar = FakeMobileCloudMirrorSubscriptionRegistrar()
    let registry = FakeMobileCloudMirrorSubscriptionRegistry(registeredAccountID: "account-a")
    let service = MobileCloudMirrorSubscriptionService(
      registrarProvider: { registrar },
      registry: registry,
      accountIDProvider: { "account-a" }
    )

    await service.registerIfNeeded()

    let ensureCount = await registrar.ensureCount()
    XCTAssertEqual(ensureCount, 0)
  }

  func testRegisterStoresAccountAfterSubscriptionSave() async {
    let registrar = FakeMobileCloudMirrorSubscriptionRegistrar()
    let registry = FakeMobileCloudMirrorSubscriptionRegistry()
    let service = MobileCloudMirrorSubscriptionService(
      registrarProvider: { registrar },
      registry: registry,
      accountIDProvider: { "account-a" }
    )

    await service.registerIfNeeded()

    let ensureCount = await registrar.ensureCount()
    let registeredAccountID = await registry.registeredAccountID()
    XCTAssertEqual(ensureCount, 1)
    XCTAssertEqual(registeredAccountID, "account-a")
  }

  func testRegisterTreatsServerRejectedRequestAsAlreadyRegistered() async {
    let registrar = FakeMobileCloudMirrorSubscriptionRegistrar(
      error: CKError(.serverRejectedRequest)
    )
    let registry = FakeMobileCloudMirrorSubscriptionRegistry()
    let service = MobileCloudMirrorSubscriptionService(
      registrarProvider: { registrar },
      registry: registry,
      accountIDProvider: { "account-a" }
    )

    await service.registerIfNeeded()

    let ensureCount = await registrar.ensureCount()
    let registeredAccountID = await registry.registeredAccountID()
    XCTAssertEqual(ensureCount, 1)
    XCTAssertEqual(registeredAccountID, "account-a")
  }

  func testInvalidateClearsRegisteredAccount() async {
    let registry = FakeMobileCloudMirrorSubscriptionRegistry(registeredAccountID: "account-a")
    let service = MobileCloudMirrorSubscriptionService(
      registrarProvider: { FakeMobileCloudMirrorSubscriptionRegistrar() },
      registry: registry,
      accountIDProvider: { "account-a" }
    )

    await service.invalidateForAccountChange()

    let registeredAccountID = await registry.registeredAccountID()
    XCTAssertNil(registeredAccountID)
  }
}

private actor FakeMobileCloudMirrorSubscriptionRegistrar:
  MobileCloudMirrorSubscriptionRegistering
{
  private var count = 0
  private let error: (any Error)?

  init(error: (any Error)? = nil) {
    self.error = error
  }

  func ensureSubscription() async throws {
    count += 1
    if let error {
      throw error
    }
  }

  func ensureCount() -> Int {
    count
  }
}

private actor FakeMobileCloudMirrorSubscriptionRegistry:
  MobileCloudMirrorSubscriptionRegistry
{
  private var accountID: String?

  init(registeredAccountID: String? = nil) {
    accountID = registeredAccountID
  }

  func registeredAccountID() async -> String? {
    accountID
  }

  func markRegistered(forAccountID accountID: String?) async {
    self.accountID = accountID
  }

  func reset() async {
    accountID = nil
  }
}

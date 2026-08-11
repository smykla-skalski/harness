import Foundation
import ServiceManagement
import Testing

@testable import HarnessMonitorKit

extension LegacyManagedLaunchAgentCleanupTests {
  @Test("Not-found legacy services are absent from the current app registration")
  func notFoundLegacyServicesAreAbsentFromCurrentAppRegistration() throws {
    let fixture = try LegacyNotFoundCleanupFixture()
    var unregisterWasCalled = false

    let completed = LegacyManagedLaunchAgentCleanup.runOnce(defaults: fixture.defaults) { _ in
      LegacyNotFoundLaunchAgentManagerStub(
        state: .notFound,
        unregisterError: LegacyNotFoundCleanupError.unregisterFailed
      ) {
        unregisterWasCalled = true
      }
    }

    #expect(completed)
    #expect(unregisterWasCalled == false)
  }

  @Test("A typed job-not-found unregister confirms absence")
  func jobNotFoundUnregisterConfirmsAbsence() throws {
    let fixture = try LegacyNotFoundCleanupFixture()
    let jobNotFound = NSError(
      domain: SMAppServiceErrorDomain,
      code: kSMErrorJobNotFound
    )
    #expect(serviceManagementJobIsAlreadyAbsent(jobNotFound))
    #expect(
      serviceManagementJobIsAlreadyAbsent(
        NSError(domain: NSCocoaErrorDomain, code: kSMErrorJobNotFound)
      ) == false
    )

    let completed = LegacyManagedLaunchAgentCleanup.runOnce(defaults: fixture.defaults) { _ in
      LegacyNotFoundLaunchAgentManagerStub(state: .notFound, unregisterError: jobNotFound)
    }

    #expect(completed)
  }

  @Test("Not-found current service still requires fail-closed unregister")
  func notFoundCurrentServiceStillRequiresUnregister() throws {
    let fixture = try LegacyNotFoundCleanupFixture()
    var currentUnregisterWasCalled = false

    let completed = LegacyManagedLaunchAgentCleanup.runOnce(defaults: fixture.defaults) { name in
      if name == HarnessMonitorPaths.launchAgentPlistName {
        return LegacyNotFoundLaunchAgentManagerStub(
          state: .notFound,
          unregisterError: LegacyNotFoundCleanupError.unregisterFailed
        ) {
          currentUnregisterWasCalled = true
        }
      }
      return LegacyNotFoundLaunchAgentManagerStub(
        state: .enabled,
        unregisterError: LegacyNotFoundCleanupError.unregisterFailed
      )
    }

    #expect(completed == false)
    #expect(currentUnregisterWasCalled)
  }
}

private final class LegacyNotFoundCleanupFixture {
  let suiteName: String
  let defaults: UserDefaults

  init() throws {
    suiteName = "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suiteName))
  }

  deinit {
    defaults.removePersistentDomain(forName: suiteName)
  }
}

private final class LegacyNotFoundLaunchAgentManagerStub:
  DaemonLaunchAgentManaging, @unchecked Sendable
{
  let state: DaemonLaunchAgentRegistrationState
  let unregisterError: Error?
  let onUnregister: () -> Void

  init(
    state: DaemonLaunchAgentRegistrationState,
    unregisterError: Error? = nil,
    onUnregister: @escaping () -> Void = {}
  ) {
    self.state = state
    self.unregisterError = unregisterError
    self.onUnregister = onUnregister
  }

  func registrationState() -> DaemonLaunchAgentRegistrationState { state }
  func register() throws {}

  func unregister() throws {
    onUnregister()
    if let unregisterError {
      throw unregisterError
    }
  }
}

private enum LegacyNotFoundCleanupError: Error {
  case unregisterFailed
}

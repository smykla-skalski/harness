import CloudKit
import Foundation

public protocol MobileCloudMirrorSubscriptionRegistering: Sendable {
  func ensureSubscription() async throws
}

extension LiveMobileCloudMirrorDatabase: MobileCloudMirrorSubscriptionRegistering {}

public protocol MobileCloudMirrorSubscriptionRegistry: Sendable {
  func registeredAccountID() async -> String?
  func markRegistered(forAccountID accountID: String?) async
  func reset() async
}

public struct UserDefaultsMobileCloudMirrorSubscriptionRegistry:
  MobileCloudMirrorSubscriptionRegistry,
  @unchecked Sendable
{
  public static let shared = UserDefaultsMobileCloudMirrorSubscriptionRegistry.live()

  public static let suiteName = "io.harnessmonitor.mobile-cloud-mirror"
  private static let defaultsKey = "subscription.registeredAccount"
  private static let unknownAccount = "<unknown>"

  private let defaults: UserDefaults

  public static func live() -> UserDefaultsMobileCloudMirrorSubscriptionRegistry {
    UserDefaultsMobileCloudMirrorSubscriptionRegistry(
      defaults: UserDefaults(suiteName: Self.suiteName) ?? .standard
    )
  }

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func registeredAccountID() async -> String? {
    defaults.string(forKey: Self.defaultsKey)
  }

  public func markRegistered(forAccountID accountID: String?) async {
    defaults.set(accountID ?? Self.unknownAccount, forKey: Self.defaultsKey)
  }

  public func reset() async {
    defaults.removeObject(forKey: Self.defaultsKey)
  }
}

public actor MobileCloudMirrorSubscriptionService {
  public static let shared = MobileCloudMirrorSubscriptionService()

  private let registrarProvider: @Sendable () -> any MobileCloudMirrorSubscriptionRegistering
  private let registry: any MobileCloudMirrorSubscriptionRegistry
  private let accountIDProvider: @Sendable () async -> String?

  public init(
    registrarProvider: @escaping @Sendable () -> any MobileCloudMirrorSubscriptionRegistering = {
      LiveMobileCloudMirrorDatabase()
    },
    registry: any MobileCloudMirrorSubscriptionRegistry =
      UserDefaultsMobileCloudMirrorSubscriptionRegistry.shared,
    accountIDProvider: @escaping @Sendable () async -> String? = {
      await MobileCloudMirrorSubscriptionService.fetchCurrentAccountID()
    }
  ) {
    self.registrarProvider = registrarProvider
    self.registry = registry
    self.accountIDProvider = accountIDProvider
  }

  public func registerIfNeeded() async {
    let currentAccountID = await accountIDProvider()
    let recordedAccountID = await registry.registeredAccountID()
    if recordedAccountID != nil, recordedAccountID == currentAccountID {
      return
    }

    do {
      try await registrarProvider().ensureSubscription()
      await registry.markRegistered(forAccountID: currentAccountID)
    } catch let error as CKError where error.code == .serverRejectedRequest {
      await registry.markRegistered(forAccountID: currentAccountID)
    } catch {
      // Silent push improves freshness; foreground refresh and widget polling remain authoritative.
    }
  }

  public func invalidateForAccountChange() async {
    await registry.reset()
  }

  public static func fetchCurrentAccountID() async -> String? {
    do {
      let recordID = try await CKContainer(identifier: "iCloud.io.harnessmonitor").userRecordID()
      return recordID.recordName
    } catch {
      return nil
    }
  }
}

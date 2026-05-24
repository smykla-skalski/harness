import CloudKit
import Foundation

public protocol SubscriptionDatabase: Sendable {
  @discardableResult
  func save(_ subscription: CKSubscription) async throws -> CKSubscription
}

extension CKDatabase: SubscriptionDatabase {}

public protocol SubscriptionRegistry: Sendable {
  func registeredAccountID() async -> String?
  func markRegistered(forAccountID accountID: String?) async
  func reset() async
}

public actor UserDefaultsSubscriptionRegistry: SubscriptionRegistry {
  public static let shared = UserDefaultsSubscriptionRegistry()

  private static let defaultsKey = "io.harnessmonitor.cloudkit.subscription.registeredAccount"
  private static let unknownAccount = "<unknown>"

  private let defaults: UserDefaults

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

public actor NeedsMeCloudKitSubscriptionService {
  public static let shared = NeedsMeCloudKitSubscriptionService()

  public static let subscriptionID = "needs-me-snapshot-changes"

  private let databaseProvider: @Sendable () -> any SubscriptionDatabase
  private let registry: any SubscriptionRegistry
  private let accountIDProvider: @Sendable () async -> String?

  public init(
    databaseProvider: @escaping @Sendable () -> any SubscriptionDatabase = {
      CloudKitContainer.privateDatabase()
    },
    registry: any SubscriptionRegistry = UserDefaultsSubscriptionRegistry.shared,
    accountIDProvider: @escaping @Sendable () async -> String? = {
      await NeedsMeCloudKitSubscriptionService.fetchCurrentAccountID()
    }
  ) {
    self.databaseProvider = databaseProvider
    self.registry = registry
    self.accountIDProvider = accountIDProvider
  }

  public func registerIfNeeded() async {
    let currentAccountID = await accountIDProvider()
    let recordedAccountID = await registry.registeredAccountID()
    if recordedAccountID != nil, recordedAccountID == currentAccountID {
      return
    }

    let subscription = CKQuerySubscription(
      recordType: CloudKitContainer.recordType,
      predicate: NSPredicate(value: true),
      subscriptionID: Self.subscriptionID,
      options: [
        .firesOnRecordCreation,
        .firesOnRecordUpdate,
        .firesOnRecordDeletion,
      ]
    )

    let notificationInfo = CKSubscription.NotificationInfo()
    notificationInfo.shouldSendContentAvailable = true
    subscription.notificationInfo = notificationInfo

    do {
      _ = try await databaseProvider().save(subscription)
      await registry.markRegistered(forAccountID: currentAccountID)
    } catch let error as CKError where error.code == .serverRejectedRequest {
      await registry.markRegistered(forAccountID: currentAccountID)
    } catch {
      // Best-effort: silent push is not required for correctness; timeline polling covers it.
    }
  }

  public func invalidateForAccountChange() async {
    await registry.reset()
  }

  internal static func fetchCurrentAccountID() async -> String? {
    do {
      let recordID = try await CloudKitContainer.container().userRecordID()
      return recordID.recordName
    } catch {
      return nil
    }
  }
}

import CloudKit
@testable import HarnessMonitorCloudKit
import XCTest

final class NeedsMeCloudKitSubscriptionServiceTests: XCTestCase {
    func testFirstRegisterIfNeededSavesSubscriptionAndMarksRegistry() async {
        let stubDB = StubSubscriptionDatabase()
        let registry = InMemorySubscriptionRegistry()
        let service = NeedsMeCloudKitSubscriptionService(
            databaseProvider: { stubDB },
            registry: registry,
            accountIDProvider: { "user-A" }
        )

        await service.registerIfNeeded()

        let saved = await stubDB.savedSubscriptions
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.subscriptionID, NeedsMeCloudKitSubscriptionService.subscriptionID)
        let recorded = await registry.registeredAccountID()
        XCTAssertEqual(recorded, "user-A")
    }

    func testSecondRegisterIfNeededWithSameAccountSkips() async {
        let stubDB = StubSubscriptionDatabase()
        let registry = InMemorySubscriptionRegistry()
        let service = NeedsMeCloudKitSubscriptionService(
            databaseProvider: { stubDB },
            registry: registry,
            accountIDProvider: { "user-A" }
        )

        await service.registerIfNeeded()
        await service.registerIfNeeded()

        let saved = await stubDB.savedSubscriptions
        XCTAssertEqual(saved.count, 1, "Second call with same account must not re-register")
    }

    func testRegisterIfNeededReRegistersAfterAccountChange() async {
        let stubDB = StubSubscriptionDatabase()
        let registry = InMemorySubscriptionRegistry()
        let accountBox = AccountIDBox(initial: "user-A")
        let service = NeedsMeCloudKitSubscriptionService(
            databaseProvider: { stubDB },
            registry: registry,
            accountIDProvider: { await accountBox.current() }
        )

        await service.registerIfNeeded()
        await accountBox.set("user-B")
        await service.registerIfNeeded()

        let saved = await stubDB.savedSubscriptions
        XCTAssertEqual(saved.count, 2, "Account ID change must trigger re-registration")
        let recorded = await registry.registeredAccountID()
        XCTAssertEqual(recorded, "user-B")
    }

    func testServerRejectedRequestStillMarksRegistered() async {
        let stubDB = StubSubscriptionDatabase()
        await stubDB.setSaveError(CKError(.serverRejectedRequest))
        let registry = InMemorySubscriptionRegistry()
        let service = NeedsMeCloudKitSubscriptionService(
            databaseProvider: { stubDB },
            registry: registry,
            accountIDProvider: { "user-A" }
        )

        await service.registerIfNeeded()

        let recorded = await registry.registeredAccountID()
        XCTAssertEqual(
            recorded,
            "user-A",
            "serverRejectedRequest means already-registered server-side; "
                + "we should mark locally so we stop retrying"
        )
    }

    func testOtherErrorsDoNotMarkRegistered() async {
        let stubDB = StubSubscriptionDatabase()
        await stubDB.setSaveError(CKError(.networkUnavailable))
        let registry = InMemorySubscriptionRegistry()
        let service = NeedsMeCloudKitSubscriptionService(
            databaseProvider: { stubDB },
            registry: registry,
            accountIDProvider: { "user-A" }
        )

        await service.registerIfNeeded()

        let recorded = await registry.registeredAccountID()
        XCTAssertNil(
            recorded,
            "Transient errors should not mark registered — next call must retry"
        )
    }

    func testInvalidateForAccountChangeResetsRegistry() async {
        let stubDB = StubSubscriptionDatabase()
        let registry = InMemorySubscriptionRegistry()
        let service = NeedsMeCloudKitSubscriptionService(
            databaseProvider: { stubDB },
            registry: registry,
            accountIDProvider: { "user-A" }
        )

        await service.registerIfNeeded()
        await service.invalidateForAccountChange()

        let recordedAfter = await registry.registeredAccountID()
        XCTAssertNil(recordedAfter)
    }

    func testUserDefaultsRegistryPersistsAcrossInstances() async {
        let suiteName = "NeedsMeCloudKitSubscriptionServiceTests.persist.\(UUID().uuidString)"
        let suite = UserDefaultsRegistrySuite(suiteName: suiteName)
        addTeardownBlock {
            await suite.removePersistentDomain()
        }

        guard let writer = await suite.makeRegistry() else {
            XCTFail("Failed to create UserDefaults suite")
            return
        }

        await writer.markRegistered(forAccountID: "user-X")

        guard let reader = await suite.makeRegistry() else {
            XCTFail("Failed to create UserDefaults suite")
            return
        }
        let read = await reader.registeredAccountID()
        XCTAssertEqual(read, "user-X")

        await writer.reset()
        let cleared = await reader.registeredAccountID()
        XCTAssertNil(cleared)
    }
}

actor StubSubscriptionDatabase: SubscriptionDatabase {
    private(set) var savedSubscriptions: [CKSubscription] = []
    private(set) var saveError: Error?

    func setSaveError(_ error: Error?) {
        saveError = error
    }

    func save(_ subscription: CKSubscription) async throws -> CKSubscription {
        if let saveError {
            throw saveError
        }
        savedSubscriptions.append(subscription)
        return subscription
    }
}

actor InMemorySubscriptionRegistry: SubscriptionRegistry {
    private var stored: String?

    func registeredAccountID() async -> String? {
        stored
    }

    func markRegistered(forAccountID accountID: String?) async {
        stored = accountID
    }

    func reset() async {
        stored = nil
    }
}

actor AccountIDBox {
    private var stored: String?

    init(initial: String?) {
        stored = initial
    }

    func current() async -> String? {
        stored
    }

    func set(_ accountID: String?) async {
        stored = accountID
    }
}

actor UserDefaultsRegistrySuite {
    private let suiteName: String
    private let defaults: UserDefaults?

    init(suiteName: String) {
        self.suiteName = suiteName
        defaults = UserDefaults(suiteName: suiteName)
    }

    func makeRegistry() -> UserDefaultsSubscriptionRegistry? {
        defaults.map(UserDefaultsSubscriptionRegistry.init(defaults:))
    }

    func removePersistentDomain() {
        defaults?.removePersistentDomain(forName: suiteName)
    }
}

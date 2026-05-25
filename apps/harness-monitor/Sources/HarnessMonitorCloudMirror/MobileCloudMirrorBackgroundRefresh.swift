import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

public protocol MobileSharedMirrorSnapshotPersisting: Sendable {
  func loadLatestSnapshot() throws -> MobileMirrorSnapshot?
  func save(_ snapshot: MobileMirrorSnapshot, savedAt: Date) throws
}

extension MobileSharedSnapshotStore: MobileSharedMirrorSnapshotPersisting {}

public struct MobileCloudMirrorBackgroundRefreshResult: Equatable, Sendable {
  public var snapshot: MobileMirrorSnapshot?
  public var previousSnapshot: MobileMirrorSnapshot?
  public var refreshedStationIDs: [String]
  public var failedStationIDs: [String]

  public init(
    snapshot: MobileMirrorSnapshot?,
    previousSnapshot: MobileMirrorSnapshot? = nil,
    refreshedStationIDs: [String],
    failedStationIDs: [String]
  ) {
    self.snapshot = snapshot
    self.previousSnapshot = previousSnapshot
    self.refreshedStationIDs = refreshedStationIDs
    self.failedStationIDs = failedStationIDs
  }

  public var didRefresh: Bool {
    !refreshedStationIDs.isEmpty
  }
}

public actor MobileCloudMirrorBackgroundRefresher {
  private let identityStore: any MobileDeviceIdentityStore
  private let credentialStore: any MobilePairedStationCredentialStore
  private let sharedSnapshotStore: (any MobileSharedMirrorSnapshotPersisting)?
  private let databaseFactory: @Sendable () -> any MobileCloudMirrorDatabase
  private let fetchTimeout: Duration

  public init(
    identityStore: any MobileDeviceIdentityStore = KeychainMobileDeviceIdentityStore(),
    credentialStore: any MobilePairedStationCredentialStore =
      KeychainMobilePairedStationCredentialStore(),
    sharedSnapshotStore: (any MobileSharedMirrorSnapshotPersisting)? = MobileSharedSnapshotStore(),
    databaseFactory: @escaping @Sendable () -> any MobileCloudMirrorDatabase = {
      LiveMobileCloudMirrorDatabase()
    },
    fetchTimeout: Duration = .seconds(20)
  ) {
    self.identityStore = identityStore
    self.credentialStore = credentialStore
    self.sharedSnapshotStore = sharedSnapshotStore
    self.databaseFactory = databaseFactory
    self.fetchTimeout = fetchTimeout
  }

  public func refresh(now: Date = .now) async -> MobileCloudMirrorBackgroundRefreshResult {
    let cachedSnapshot = try? sharedSnapshotStore?.loadLatestSnapshot()
    var aggregateSnapshot = cachedSnapshot ?? MobileMirrorSnapshot.empty(now: now)
    let credentials: [MobilePairedStationCredential]
    do {
      credentials = try await credentialStore.loadAll()
    } catch {
      return MobileCloudMirrorBackgroundRefreshResult(
        snapshot: cachedSnapshot,
        previousSnapshot: cachedSnapshot,
        refreshedStationIDs: [],
        failedStationIDs: []
      )
    }

    guard !credentials.isEmpty else {
      return MobileCloudMirrorBackgroundRefreshResult(
        snapshot: cachedSnapshot,
        previousSnapshot: cachedSnapshot,
        refreshedStationIDs: [],
        failedStationIDs: []
      )
    }

    let defaultStationID =
      credentials.first(where: \.defaultStation)?.stationID
      ?? credentials.first?.stationID
    let placeholdersChanged = aggregateSnapshot.ensurePairedStationPlaceholders(
      for: credentials,
      defaultStationID: defaultStationID,
      now: now
    )
    var refreshedStationIDs: [String] = []
    var failedStationIDs: [String] = []

    for credential in credentials {
      do {
        guard let identity = try await identityStore.load(id: credential.deviceIdentityID) else {
          failedStationIDs.append(credential.stationID)
          continue
        }
        let client = MobileCloudMirrorSyncClient(
          database: databaseFactory(),
          cipher: MobilePayloadCipher(rawKey: credential.symmetricKeyRawRepresentation),
          deviceIdentity: identity,
          commandKeyID: credential.commandKeyID
        )
        let stationSnapshot = try await MobileAsyncTimeout.run(
          timeout: fetchTimeout,
          timeoutError: { MobileMirrorRefreshTimeout() },
          operation: {
            try await client.fetchLatestSnapshot(stationID: credential.stationID, now: now)
          }
        )
        guard let stationSnapshot else {
          failedStationIDs.append(credential.stationID)
          continue
        }
        aggregateSnapshot = aggregateSnapshot.mergingStationSnapshot(
          stationSnapshot,
          stationID: credential.stationID,
          defaultStationID: defaultStationID
        )
        refreshedStationIDs.append(credential.stationID)
      } catch {
        failedStationIDs.append(credential.stationID)
      }
    }

    guard !refreshedStationIDs.isEmpty else {
      if placeholdersChanged {
        try? sharedSnapshotStore?.save(aggregateSnapshot, savedAt: now)
      }
      return MobileCloudMirrorBackgroundRefreshResult(
        snapshot: placeholdersChanged ? aggregateSnapshot : cachedSnapshot,
        previousSnapshot: cachedSnapshot,
        refreshedStationIDs: [],
        failedStationIDs: failedStationIDs
      )
    }

    try? sharedSnapshotStore?.save(aggregateSnapshot, savedAt: now)
    return MobileCloudMirrorBackgroundRefreshResult(
      snapshot: aggregateSnapshot,
      previousSnapshot: cachedSnapshot,
      refreshedStationIDs: refreshedStationIDs,
      failedStationIDs: failedStationIDs
    )
  }
}

import CloudKit
import Foundation

public actor NeedsMeCloudKitStore {
  private let database: any NeedsMeCloudKitDatabase
  private var cachedSnapshot: NeedsMeSnapshot?

  public init(database: any NeedsMeCloudKitDatabase = LiveCloudKitDatabase()) {
    self.database = database
  }

  public func fetchCurrent() async throws -> NeedsMeSnapshot? {
    do {
      let fetched = try await database.fetchSnapshot()
      if let fetched {
        cachedSnapshot = fetched
      }
      return fetched
    } catch let error as CKError {
      throw Self.map(error)
    }
  }

  @discardableResult
  public func upsert(count: Int64, updatedAt: Date) async throws -> Int64 {
    let previousRevision = try await currentRevision()
    let snapshot = NeedsMeSnapshot(
      count: count,
      updatedAt: updatedAt,
      revision: previousRevision + 1
    )
    do {
      try await database.upsertSnapshot(snapshot)
      cachedSnapshot = snapshot
      return snapshot.revision
    } catch let error as CKError {
      throw Self.map(error)
    }
  }

  private func currentRevision() async throws -> Int64 {
    if let cachedSnapshot {
      return cachedSnapshot.revision
    }
    do {
      let fetched = try await database.fetchSnapshot()
      cachedSnapshot = fetched
      return fetched?.revision ?? 0
    } catch let error as CKError where error.code == .unknownItem {
      return 0
    } catch let error as CKError {
      throw Self.map(error)
    }
  }

  private static func map(_ error: CKError) -> NeedsMeCloudKitError {
    switch error.code {
    case .notAuthenticated:
      return .notAuthenticated
    case .networkUnavailable, .networkFailure:
      return .networkUnavailable
    case .quotaExceeded:
      return .quotaExceeded
    default:
      return .underlying(error.localizedDescription)
    }
  }
}

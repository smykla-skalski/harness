import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import WidgetKit

enum WatchMirrorTimelineState: Equatable {
  case preview
  case live(Date)
  case unpaired
  case stale

  var shortTitle: String {
    switch self {
    case .preview: "Demo"
    case .live: "Live"
    case .unpaired: "Pair Mac"
    case .stale: "Stale"
    }
  }
}

struct WatchMirrorTimelineEntry: TimelineEntry {
  let date: Date
  let snapshot: MobileMirrorSnapshot
  let state: WatchMirrorTimelineState
}

struct WatchMirrorTimelineProvider: TimelineProvider {
  typealias Entry = WatchMirrorTimelineEntry
  private static let fetchTimeout: Duration = .seconds(20)

  func placeholder(in context: Context) -> WatchMirrorTimelineEntry {
    WatchMirrorTimelineEntry(
      date: .now,
      snapshot: MobileDemoFixtures.snapshot(),
      state: .preview
    )
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (WatchMirrorTimelineEntry) -> Void
  ) {
    nonisolated(unsafe) let safeCompletion = completion
    let isPreview = context.isPreview
    Task {
      safeCompletion(await Self.entry(isPreview: isPreview))
    }
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<WatchMirrorTimelineEntry>) -> Void
  ) {
    nonisolated(unsafe) let safeCompletion = completion
    let isPreview = context.isPreview
    Task {
      let now = Date()
      let entry = await Self.entry(isPreview: isPreview, now: now)
      safeCompletion(
        Timeline(
          entries: [entry],
          policy: .after(now.addingTimeInterval(entry.refreshInterval))
        )
      )
    }
  }

  private static func entry(
    isPreview: Bool,
    now: Date = .now
  ) async -> WatchMirrorTimelineEntry {
    if isPreview {
      return WatchMirrorTimelineEntry(
        date: now,
        snapshot: MobileDemoFixtures.snapshot(now: now),
        state: .preview
      )
    }
    let cachedSnapshot = latestSharedSnapshot()

    do {
      let credentialStore = KeychainMobilePairedStationCredentialStore()
      let identityStore = KeychainMobileDeviceIdentityStore()
      guard let credential = try await credentialStore.loadAll().first else {
        return fallbackEntry(
          cachedSnapshot: cachedSnapshot,
          emptyState: .unpaired,
          now: now
        )
      }
      guard let identity = try await identityStore.load(id: credential.deviceIdentityID) else {
        return fallbackEntry(
          cachedSnapshot: cachedSnapshot,
          emptyState: .unpaired,
          now: now
        )
      }

      let client = MobileCloudMirrorSyncClient(
        database: LiveMobileCloudMirrorDatabase(),
        cipher: MobilePayloadCipher(rawKey: credential.symmetricKeyRawRepresentation),
        deviceIdentity: identity,
        commandKeyID: credential.commandKeyID
      )
      let snapshot = try await MobileAsyncTimeout.run(
        timeout: fetchTimeout,
        timeoutError: { MobileMirrorRefreshTimeout() }
      ) {
        try await client.fetchLatestSnapshot(stationID: credential.stationID, now: now)
      }
      guard let snapshot else {
        return fallbackEntry(
          cachedSnapshot: cachedSnapshot,
          emptyState: .stale,
          now: now
        )
      }
      try? MobileSharedSnapshotStore()?.save(snapshot, savedAt: now)
      return WatchMirrorTimelineEntry(
        date: now, snapshot: snapshot, state: .live(snapshot.generatedAt))
    } catch {
      return fallbackEntry(
        cachedSnapshot: cachedSnapshot,
        emptyState: .stale,
        now: now
      )
    }
  }

  private static func latestSharedSnapshot() -> MobileMirrorSnapshot? {
    guard let store = MobileSharedSnapshotStore() else {
      return nil
    }
    return try? store.loadLatestSnapshot()
  }

  private static func fallbackEntry(
    cachedSnapshot: MobileMirrorSnapshot?,
    emptyState: WatchMirrorTimelineState,
    now: Date
  ) -> WatchMirrorTimelineEntry {
    guard let cachedSnapshot else {
      return WatchMirrorTimelineEntry(date: now, snapshot: .empty(now: now), state: emptyState)
    }
    let state: WatchMirrorTimelineState =
      cachedSnapshot.expiresAt > now
      ? .live(cachedSnapshot.generatedAt)
      : .stale
    return WatchMirrorTimelineEntry(date: now, snapshot: cachedSnapshot, state: state)
  }
}

extension WatchMirrorTimelineEntry {
  var refreshInterval: TimeInterval {
    switch state {
    case .preview, .live:
      5 * 60
    case .unpaired, .stale:
      15 * 60
    }
  }
}

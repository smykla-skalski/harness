import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import WidgetKit

enum MobileMirrorTimelineState: Equatable {
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

struct MobileMirrorEntry: TimelineEntry {
  let date: Date
  let snapshot: MobileMirrorSnapshot
  let state: MobileMirrorTimelineState
}

struct MobileMirrorTimelineProvider: TimelineProvider {
  typealias Entry = MobileMirrorEntry
  private static let fetchTimeout: Duration = .seconds(20)

  func placeholder(in context: Context) -> MobileMirrorEntry {
    MobileMirrorEntry(date: .now, snapshot: MobileDemoFixtures.snapshot(), state: .preview)
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (MobileMirrorEntry) -> Void
  ) {
    nonisolated(unsafe) let safeCompletion = completion
    let isPreview = context.isPreview
    Task {
      safeCompletion(await Self.entry(isPreview: isPreview))
    }
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<MobileMirrorEntry>) -> Void
  ) {
    nonisolated(unsafe) let safeCompletion = completion
    let isPreview = context.isPreview
    Task {
      let now = Date()
      let entry = await Self.entry(isPreview: isPreview, now: now)
      safeCompletion(
        Timeline(entries: [entry], policy: .after(now.addingTimeInterval(entry.refreshInterval)))
      )
    }
  }

  private static func entry(
    isPreview: Bool,
    now: Date = .now
  ) async -> MobileMirrorEntry {
    if isPreview {
      return MobileMirrorEntry(
        date: now,
        snapshot: MobileDemoFixtures.snapshot(now: now),
        state: .preview
      )
    }
    let cachedSnapshot = latestSharedSnapshot()
    let credentialStore = KeychainMobilePairedStationCredentialStore()
    do {
      guard !(try await credentialStore.loadAll()).isEmpty else {
        return fallbackEntry(cachedSnapshot: cachedSnapshot, emptyState: .unpaired, now: now)
      }
      let result = await MobileCloudMirrorBackgroundRefresher(
        fetchTimeout: fetchTimeout
      ).refresh(now: now)
      guard result.didRefresh, let snapshot = result.snapshot else {
        return fallbackEntry(
          cachedSnapshot: result.snapshot ?? cachedSnapshot,
          emptyState: .stale,
          now: now
        )
      }
      return MobileMirrorEntry(date: now, snapshot: snapshot, state: .live(snapshot.generatedAt))
    } catch {
      return fallbackEntry(cachedSnapshot: cachedSnapshot, emptyState: .stale, now: now)
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
    emptyState: MobileMirrorTimelineState,
    now: Date
  ) -> MobileMirrorEntry {
    guard let cachedSnapshot else {
      return MobileMirrorEntry(date: now, snapshot: .empty(now: now), state: emptyState)
    }
    let state: MobileMirrorTimelineState =
      cachedSnapshot.expiresAt > now
      ? .live(cachedSnapshot.generatedAt)
      : .stale
    return MobileMirrorEntry(date: now, snapshot: cachedSnapshot, state: state)
  }
}

extension MobileMirrorEntry {
  var refreshInterval: TimeInterval {
    switch state {
    case .preview, .live:
      5 * 60
    case .unpaired, .stale:
      15 * 60
    }
  }

  var primaryAttention: MobileAttentionItem? {
    snapshot.sortedAttention.first
  }

  var activeCommandPresentation: MobileCommandLiveActivityPresentation? {
    MobileCommandLiveActivityPresentation.activeCommand(in: snapshot, now: date)
  }

  var stationHealthSummary: MobileStationHealthSummary {
    let stations = snapshot.stations
    let onlineCount = stations.filter { $0.state == .online }.count
    let station = stations.sorted(by: MobileStationHealthSummary.stationPrecedes).first
    return MobileStationHealthSummary(
      station: station,
      onlineCount: onlineCount,
      stationCount: stations.count
    )
  }
}

struct MobileStationHealthSummary {
  let station: MobileStationSummary?
  let onlineCount: Int
  let stationCount: Int

  var title: String {
    station?.displayName ?? "No paired Macs"
  }

  var subtitle: String {
    guard let station else {
      return "Pair from Settings"
    }
    return "\(station.state.title) - \(station.activeSessionCount) active"
  }

  var countText: String {
    "\(onlineCount)/\(stationCount)"
  }

  static func stationPrecedes(_ lhs: MobileStationSummary, _ rhs: MobileStationSummary) -> Bool {
    if lhs.state.widgetRank != rhs.state.widgetRank {
      return lhs.state.widgetRank < rhs.state.widgetRank
    }
    if lhs.needsYouCount != rhs.needsYouCount {
      return lhs.needsYouCount > rhs.needsYouCount
    }
    return lhs.lastSeenAt > rhs.lastSeenAt
  }
}

extension MobileStationState {
  fileprivate var widgetRank: Int {
    switch self {
    case .offline: 0
    case .stale: 1
    case .online: 2
    }
  }
}

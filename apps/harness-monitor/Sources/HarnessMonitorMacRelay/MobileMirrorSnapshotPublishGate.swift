import Foundation
import HarnessMonitorCore

/// Decides whether a freshly built mirror is worth writing to CloudKit.
///
/// The relay rebuilds the whole mirror on every poll, and each rebuild gets a
/// new revision plus fresh `generatedAt`, `expiresAt`, and station `lastSeenAt`
/// stamps. Two consecutive snapshots are therefore never equal even when
/// nothing the phone renders has changed, so a plain equality check would never
/// skip anything. Compare the content with those four fields normalized
/// instead.
struct MobileMirrorSnapshotPublishGate {
  /// An idle Mac still has to touch the record periodically: the phone reads
  /// `lastSeenAt` to decide the station is alive, and the record is dropped
  /// once it passes `expiresAt`.
  static let heartbeat: TimeInterval = 60

  private var lastPublishedContent: MobileMirrorSnapshot?
  private var lastPublishedAt: Date?

  func shouldPublish(_ snapshot: MobileMirrorSnapshot, now: Date) -> Bool {
    guard let lastPublishedContent, let lastPublishedAt else {
      return true
    }
    // A clock that moved backwards would otherwise read as "still inside the
    // heartbeat" and suppress writes until wall time caught up.
    let elapsed = now.timeIntervalSince(lastPublishedAt)
    guard elapsed >= 0, elapsed < Self.heartbeat else {
      return true
    }
    return Self.comparableContent(snapshot) != lastPublishedContent
  }

  /// Call only after the write succeeded, so a failed upload cannot convince the
  /// gate that the phone already has this content.
  mutating func recordPublished(_ snapshot: MobileMirrorSnapshot, at now: Date) {
    lastPublishedContent = Self.comparableContent(snapshot)
    lastPublishedAt = now
  }

  static func comparableContent(_ snapshot: MobileMirrorSnapshot) -> MobileMirrorSnapshot {
    var normalized = snapshot
    normalized.revision = 0
    normalized.generatedAt = .distantPast
    normalized.expiresAt = .distantPast
    normalized.stations = snapshot.stations.map { station in
      var stable = station
      stable.lastSeenAt = .distantPast
      return stable
    }
    return normalized
  }
}

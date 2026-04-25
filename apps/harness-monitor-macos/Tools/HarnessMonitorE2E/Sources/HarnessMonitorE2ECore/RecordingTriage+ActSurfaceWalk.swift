import Foundation

extension RecordingTriage {
  public struct ActSurfaceReport: Codable, Equatable, Sendable {
    public struct PerAct: Codable, Equatable, Sendable {
      public let act: String
      public let payload: [String: String]
      public let identifierCount: Int
      public let findings: [ChecklistFinding]

      public init(
        act: String,
        payload: [String: String],
        identifierCount: Int,
        findings: [ChecklistFinding]
      ) {
        self.act = act
        self.payload = payload
        self.identifierCount = identifierCount
        self.findings = findings
      }
    }

    public let perAct: [PerAct]
    public let wholeRun: [ChecklistFinding]

    public init(perAct: [PerAct], wholeRun: [ChecklistFinding]) {
      self.perAct = perAct
      self.wholeRun = wholeRun
    }
  }

  /// Walk every `<act>.ready` marker in `markerDir`, locate the matching
  /// `swarm-<act>.txt` hierarchy in `uiSnapshotsDir`, and assemble a single
  /// ActSurfaceReport that pairs `assertActSurface` per-act findings with
  /// `assertWholeRunInvariants` cross-act findings. If `taskReviewID` is nil,
  /// the helper falls back to whichever marker payload carries `task_review_id`.
  public static func walkRecordingActs(
    markerDir: URL,
    uiSnapshotsDir: URL,
    taskReviewID: String?
  ) throws -> ActSurfaceReport {
    let entries = try FileManager.default.contentsOfDirectory(
      at: markerDir, includingPropertiesForKeys: nil)
    var markers: [ActMarker] = []
    for url in entries where url.pathExtension == "ready" {
      markers.append(try parseActMarker(at: url))
    }
    markers.sort { $0.act < $1.act }
    var perAct: [ActSurfaceReport.PerAct] = []
    var hierarchies: [ActHierarchy] = []
    var derivedTaskReviewID = taskReviewID
    for marker in markers {
      let snapshot = uiSnapshotsDir.appendingPathComponent("swarm-\(marker.act).txt")
      var identifiers: [AccessibilityIdentifier] = []
      if FileManager.default.fileExists(atPath: snapshot.path),
        let text = try? String(contentsOf: snapshot, encoding: .utf8)
      {
        identifiers = parseAccessibilityIdentifiers(from: text)
      }
      let findings = assertActSurface(
        act: marker.act,
        payload: marker.payload,
        identifiers: identifiers
      )
      perAct.append(
        .init(
          act: marker.act,
          payload: marker.payload,
          identifierCount: identifiers.count,
          findings: findings
        ))
      hierarchies.append(ActHierarchy(act: marker.act, identifiers: identifiers))
      if derivedTaskReviewID == nil,
        let reviewID = marker.payload["task_review_id"],
        !reviewID.isEmpty
      {
        derivedTaskReviewID = reviewID
      }
    }
    let wholeRun = assertWholeRunInvariants(
      perActHierarchies: hierarchies,
      taskReviewID: derivedTaskReviewID
    )
    return ActSurfaceReport(perAct: perAct, wholeRun: wholeRun)
  }
}

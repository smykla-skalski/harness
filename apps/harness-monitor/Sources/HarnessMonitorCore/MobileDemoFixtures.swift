import Foundation

public enum MobileDemoFixtures {
  public static func snapshot(now: Date = .now) -> MobileMirrorSnapshot {
    let stations = demoStations(now: now)
    let targets = demoTargets(stationID: stations.station.id)

    return MobileMirrorSnapshot(
      revision: 42,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60),
      stations: [stations.station, stations.laptop],
      attention: demoAttentionItems(
        station: stations.station,
        laptop: stations.laptop,
        permissionTarget: targets.permissionTarget,
        reviewTarget: targets.reviewTarget,
        now: now
      ),
      sessions: demoSessions(
        station: stations.station,
        laptop: stations.laptop,
        now: now
      ),
      reviews: demoReviews(stationID: stations.station.id, now: now),
      taskBoardItems: demoTaskBoardItems(
        station: stations.station,
        laptop: stations.laptop,
        now: now
      ),
      commands: demoCommands(
        station: stations.station,
        laptop: stations.laptop,
        reviewTarget: targets.reviewTarget,
        now: now
      ),
      trustedDevices: demoTrustedDevices(now: now)
    )
  }
}

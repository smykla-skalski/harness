extension RecordingTriage {
  public struct ThrashWindow: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let perceptualChanges: Int
  }

  public struct ThrashReport: Codable, Equatable, Sendable {
    public let windowSeconds: Double
    public let changeThreshold: Int
    public let windows: [ThrashWindow]
  }

  /// Sampled perceptual-hash distances per frame keyed by wall-clock seconds
  /// since the first frame. Detects regions of the recording where the same
  /// 500 ms window contains more than `changeThreshold` significant
  /// perceptual changes (a proxy for flicker / animation thrash).
  public static func detectAnimationThrash(
    sampledHashes: [(seconds: Double, hash: PerceptualHash)],
    windowSeconds: Double = 0.5,
    distanceThreshold: Int = 8,
    changeThreshold: Int = 3
  ) -> ThrashReport {
    guard sampledHashes.count >= 2 else {
      return ThrashReport(
        windowSeconds: windowSeconds,
        changeThreshold: changeThreshold,
        windows: []
      )
    }

    var changes: [Double] = []
    for index in 1..<sampledHashes.count {
      let previous = sampledHashes[index - 1]
      let current = sampledHashes[index]
      if previous.hash.distance(to: current.hash) > distanceThreshold {
        changes.append(current.seconds)
      }
    }

    var windows: [ThrashWindow] = []
    var pointer = 0
    for change in changes {
      let windowStart = change
      let windowEnd = change + windowSeconds
      var count = 0
      while pointer < changes.count, changes[pointer] < windowStart {
        pointer += 1
      }
      for laterChange in changes[pointer...] {
        guard laterChange < windowEnd else {
          break
        }
        count += 1
      }
      if count > changeThreshold {
        windows.append(
          ThrashWindow(
            startSeconds: windowStart,
            endSeconds: windowEnd,
            perceptualChanges: count
          ))
      }
    }
    return ThrashReport(
      windowSeconds: windowSeconds,
      changeThreshold: changeThreshold,
      windows: windows
    )
  }
}

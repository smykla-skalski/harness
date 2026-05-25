import Foundation

public enum NeedsMeCountState: Equatable, Sendable {
  case live
  case cached
  case notAuthenticated
  case offline
  case unknownError
}

public struct NeedsMeCountResolution: Equatable, Sendable {
  public let count: Int
  public let updatedAt: Date?
  public let state: NeedsMeCountState

  public init(count: Int, updatedAt: Date?, state: NeedsMeCountState) {
    self.count = count
    self.updatedAt = updatedAt
    self.state = state
  }
}

public enum NeedsMeCountResolver {
  public static func resolve(
    primary: NeedsMeSnapshot?,
    fallback: NeedsMeSnapshot?,
    error: NeedsMeCloudKitError?
  ) -> NeedsMeCountResolution {
    if let primary {
      return NeedsMeCountResolution(
        count: Int(primary.count),
        updatedAt: primary.updatedAt,
        state: .live
      )
    }

    switch error {
    case .none:
      if let fallback {
        return NeedsMeCountResolution(
          count: Int(fallback.count),
          updatedAt: fallback.updatedAt,
          state: .cached
        )
      }
      return NeedsMeCountResolution(count: 0, updatedAt: nil, state: .live)
    case .some(.notAuthenticated):
      return resolution(fallback: fallback, state: .notAuthenticated)
    case .some(.networkUnavailable):
      if let fallback {
        return NeedsMeCountResolution(
          count: Int(fallback.count),
          updatedAt: fallback.updatedAt,
          state: .cached
        )
      }
      return NeedsMeCountResolution(count: 0, updatedAt: nil, state: .offline)
    case .some(.quotaExceeded), .some(.underlying):
      return resolution(fallback: fallback, state: .unknownError)
    }
  }

  private static func resolution(
    fallback: NeedsMeSnapshot?,
    state: NeedsMeCountState
  ) -> NeedsMeCountResolution {
    if let fallback {
      return NeedsMeCountResolution(
        count: Int(fallback.count),
        updatedAt: fallback.updatedAt,
        state: state
      )
    }
    return NeedsMeCountResolution(count: 0, updatedAt: nil, state: state)
  }
}

public enum NeedsMeStalenessClassifier {
  public static let defaultThreshold: TimeInterval = 60 * 60

  public static func isStale(
    updatedAt: Date?,
    now: Date = Date(),
    threshold: TimeInterval = Self.defaultThreshold
  ) -> Bool {
    guard let updatedAt else { return false }
    return now.timeIntervalSince(updatedAt) > threshold
  }
}

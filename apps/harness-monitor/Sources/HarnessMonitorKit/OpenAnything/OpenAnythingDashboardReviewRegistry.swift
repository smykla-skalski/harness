import Foundation
import Observation
import SwiftUI

public struct DashboardReviewSelectionRequest: Equatable, Hashable, Sendable {
  public let requestID: Int
  public let pullRequestID: String

  public init(requestID: Int, pullRequestID: String) {
    self.requestID = requestID
    self.pullRequestID = pullRequestID
  }
}

@MainActor
@Observable
public final class OpenAnythingDashboardReviewRegistry {
  public private(set) var loadedItems: [ReviewItem] = []
  public private(set) var selectionRequest: DashboardReviewSelectionRequest?
  private var selectionSequence = 0

  public init() {}

  public func replaceLoadedItems(_ items: [ReviewItem]) {
    guard loadedItems != items else { return }
    loadedItems = items
  }

  public func requestSelection(pullRequestID: String) {
    selectionSequence += 1
    selectionRequest = DashboardReviewSelectionRequest(
      requestID: selectionSequence,
      pullRequestID: pullRequestID
    )
  }

  public func finishSelection(requestID: Int) {
    guard selectionRequest?.requestID == requestID else {
      return
    }
    selectionRequest = nil
  }
}

/// Threads the dashboard review registry from the app scene down to the
/// reviews route via SwiftUI's environment. The default value is a fresh
/// instance so previews and tests that mount the route without explicit
/// injection still get a working (but empty) registry rather than the
/// process-wide singleton that used to back this surface.
private struct OpenAnythingDashboardReviewRegistryKey: @preconcurrency EnvironmentKey {
  @MainActor static let defaultValue = OpenAnythingDashboardReviewRegistry()
}

extension EnvironmentValues {
  public var openAnythingDashboardReviewRegistry: OpenAnythingDashboardReviewRegistry {
    get { self[OpenAnythingDashboardReviewRegistryKey.self] }
    set { self[OpenAnythingDashboardReviewRegistryKey.self] = newValue }
  }
}

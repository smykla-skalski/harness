import Foundation
import Observation
import SwiftUI

public struct DashboardReviewSelectionRequest: Equatable, Hashable, Sendable {
  public let requestID: Int
  public let pullRequestID: String
  /// File to open inside the PR (Files detail mode). `nil` selects the PR only.
  public let filePath: String?
  /// Line range to highlight and scroll to within `filePath`.
  public let lineSelection: ReviewLineSelection?

  public init(
    requestID: Int,
    pullRequestID: String,
    filePath: String? = nil,
    lineSelection: ReviewLineSelection? = nil
  ) {
    self.requestID = requestID
    self.pullRequestID = pullRequestID
    self.filePath = filePath
    self.lineSelection = lineSelection
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

  public func requestSelection(
    pullRequestID: String,
    filePath: String? = nil,
    lineSelection: ReviewLineSelection? = nil
  ) {
    selectionSequence += 1
    selectionRequest = DashboardReviewSelectionRequest(
      requestID: selectionSequence,
      pullRequestID: pullRequestID,
      filePath: filePath,
      lineSelection: lineSelection
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

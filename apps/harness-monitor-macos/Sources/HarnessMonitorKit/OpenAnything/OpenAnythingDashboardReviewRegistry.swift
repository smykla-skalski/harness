import Foundation
import Observation

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
  public static let shared = OpenAnythingDashboardReviewRegistry()

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

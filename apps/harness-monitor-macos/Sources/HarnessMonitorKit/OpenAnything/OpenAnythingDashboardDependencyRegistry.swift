import Foundation
import Observation

public struct DashboardDependencySelectionRequest: Equatable, Hashable, Sendable {
  public let requestID: Int
  public let pullRequestID: String

  public init(requestID: Int, pullRequestID: String) {
    self.requestID = requestID
    self.pullRequestID = pullRequestID
  }
}

@MainActor
@Observable
public final class OpenAnythingDashboardDependencyRegistry {
  public static let shared = OpenAnythingDashboardDependencyRegistry()

  public private(set) var loadedItems: [DependencyUpdateItem] = []
  public private(set) var selectionRequest: DashboardDependencySelectionRequest?
  private var selectionSequence = 0

  public init() {}

  public func replaceLoadedItems(_ items: [DependencyUpdateItem]) {
    guard loadedItems != items else { return }
    loadedItems = items
  }

  public func requestSelection(pullRequestID: String) {
    selectionSequence += 1
    selectionRequest = DashboardDependencySelectionRequest(
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

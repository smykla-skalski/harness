import HarnessMonitorKit
import SwiftUI

struct DashboardReviewsPinnedPullRequests: Codable, Equatable {
  static let storageKey = "dashboard.reviews.pinned-pull-requests"

  var pullRequestIDs: [String] = []

  init(pullRequestIDs: [String] = []) {
    self.pullRequestIDs = pullRequestIDs
  }

  init(storedValue: String) {
    self = Self.decode(from: storedValue)
  }

  var encodedString: String {
    DashboardReviewsStorageCodec.encodeToString(self)
  }

  func contains(_ pullRequestID: String) -> Bool {
    pullRequestIDs.contains(pullRequestID)
  }

  @discardableResult
  mutating func pin(_ pullRequestID: String) -> Bool {
    guard !contains(pullRequestID) else { return false }
    pullRequestIDs.append(pullRequestID)
    return true
  }

  @discardableResult
  mutating func unpin(_ pullRequestID: String) -> Bool {
    guard let index = pullRequestIDs.firstIndex(of: pullRequestID) else {
      return false
    }
    pullRequestIDs.remove(at: index)
    return true
  }

  static func decode(from string: String) -> Self {
    DashboardReviewsStorageCodec.decode(Self.self, from: string) ?? Self()
  }

  /// Read-modify-write the persisted pinned set directly in `defaults`. Lets a
  /// caller outside the Reviews view (the Open Anything palette) pin or unpin a
  /// PR durably even when the Reviews pane is not mounted. A mounted
  /// ``DashboardReviewsRouteView`` reconciles its in-memory copy through its
  /// existing `.onChange(of: pinnedPullRequestIDsStorage)` handler. Returns the
  /// resulting pinned state.
  @discardableResult
  static func togglePersisted(
    pullRequestID: String,
    in defaults: UserDefaults = .standard
  ) -> Bool {
    var current = decode(from: defaults.string(forKey: storageKey) ?? "")
    let nowPinned: Bool
    if current.contains(pullRequestID) {
      current.unpin(pullRequestID)
      nowPinned = false
    } else {
      current.pin(pullRequestID)
      nowPinned = true
    }
    defaults.set(current.encodedString, forKey: storageKey)
    return nowPinned
  }

  /// Whether `pullRequestID` is currently pinned in the persisted store.
  static func isPersistedPinned(
    pullRequestID: String,
    in defaults: UserDefaults = .standard
  ) -> Bool {
    decode(from: defaults.string(forKey: storageKey) ?? "").contains(pullRequestID)
  }
}

/// The pull-request id an Open Anything `target` points at, or `nil` when the
/// target is not a review. Lets the palette offer a Reviews-pin affordance only
/// for pull-request rows.
public func reviewPullRequestID(for target: OpenAnythingTarget) -> String? {
  guard case .review(let pullRequestID) = target else { return nil }
  return pullRequestID
}

/// Toggle a pull request's durable Reviews pin and report the resulting state
/// through `presentFeedback` (the pin-and-stay success toast). The palette stays
/// open after the toggle, so the caller surfaces the toast rather than dismissing.
public func toggleReviewPin(
  pullRequestID: String,
  in defaults: UserDefaults = .standard,
  presentFeedback: (String) -> Void
) {
  let nowPinned = DashboardReviewsPinnedPullRequests.togglePersisted(
    pullRequestID: pullRequestID,
    in: defaults
  )
  presentFeedback(nowPinned ? "Pinned to Reviews" : "Unpinned from Reviews")
}

enum DashboardReviewsPinSelectionIntent: Equatable {
  case pin
  case unpin
}

func dashboardReviewsPinSelectionIntent(
  items: [ReviewItem],
  pinnedPullRequestIDs: [String]
) -> DashboardReviewsPinSelectionIntent? {
  guard !items.isEmpty else { return nil }
  let pinned = Set(pinnedPullRequestIDs)
  if items.allSatisfy({ pinned.contains($0.pullRequestID) }) {
    return .unpin
  }
  return .pin
}

func dashboardReviewsPinSelectionMenuTitle(
  itemCount: Int,
  intent: DashboardReviewsPinSelectionIntent
) -> String {
  switch (intent, itemCount) {
  case (.pin, 1):
    "Pin Pull Request"
  case (.unpin, 1):
    "Unpin Pull Request"
  case (.pin, _):
    "Pin Selection"
  case (.unpin, _):
    "Unpin Selection"
  }
}

func dashboardReviewsPinSelectionSuccessMessage(
  itemCount: Int,
  intent: DashboardReviewsPinSelectionIntent
) -> String {
  let verb = intent == .pin ? "Pinned" : "Unpinned"
  let noun = itemCount == 1 ? "pull request" : "pull requests"
  return "\(verb) \(itemCount) \(noun)"
}

extension DashboardReviewsRouteView {
  func isPullRequestPinned(_ pullRequestID: String) -> Bool {
    routePinnedPullRequests.contains(pullRequestID)
  }

  func pinSelectionMenuTitle(for items: [ReviewItem]) -> String {
    guard
      let intent = dashboardReviewsPinSelectionIntent(
        items: items,
        pinnedPullRequestIDs: routePinnedPullRequests.pullRequestIDs
      )
    else {
      return "Pin Selection"
    }
    return dashboardReviewsPinSelectionMenuTitle(itemCount: items.count, intent: intent)
  }

  func togglePinnedSelection(items: [ReviewItem]) {
    guard
      let intent = dashboardReviewsPinSelectionIntent(
        items: items,
        pinnedPullRequestIDs: routePinnedPullRequests.pullRequestIDs
      )
    else {
      return
    }
    var next = routePinnedPullRequests
    let pullRequestIDs = items.map(\.pullRequestID).removingDuplicates()
    for pullRequestID in pullRequestIDs {
      switch intent {
      case .pin:
        _ = next.pin(pullRequestID)
      case .unpin:
        _ = next.unpin(pullRequestID)
      }
    }
    guard next != routePinnedPullRequests else { return }
    routePinnedPullRequests = next
    routePinnedPullRequestIDsStorage = next.encodedString
    store.presentSuccessFeedback(
      dashboardReviewsPinSelectionSuccessMessage(
        itemCount: pullRequestIDs.count,
        intent: intent
      )
    )
  }
}

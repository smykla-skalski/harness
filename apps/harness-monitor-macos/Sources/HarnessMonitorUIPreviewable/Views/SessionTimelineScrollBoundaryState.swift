import SwiftUI

struct SessionTimelineScrollBoundaryState: Equatable {
  private static let triggerDistance: CGFloat = 96
  private static let bucketSize: CGFloat = 24

  private let topBucket: Int?
  private let bottomBucket: Int?

  init(geometry: ScrollGeometry) {
    self.init(
      visibleMinY: geometry.visibleRect.minY,
      visibleMaxY: geometry.visibleRect.maxY,
      contentHeight: geometry.contentSize.height
    )
  }

  init(
    visibleMinY: CGFloat,
    visibleMaxY: CGFloat,
    contentHeight: CGFloat
  ) {
    topBucket =
      visibleMinY <= Self.triggerDistance
      ? Self.bucket(for: visibleMinY)
      : nil
    bottomBucket =
      contentHeight - visibleMaxY <= Self.triggerDistance
      ? Self.bucket(for: visibleMaxY)
      : nil
  }

  func enteredTopEdge(from oldValue: Self) -> Bool {
    enteredEdge(topBucket, from: oldValue.topBucket)
  }

  func enteredBottomEdge(from oldValue: Self) -> Bool {
    enteredEdge(bottomBucket, from: oldValue.bottomBucket)
  }

  private func enteredEdge(_ newBucket: Int?, from oldBucket: Int?) -> Bool {
    guard let newBucket else {
      return false
    }
    return oldBucket != newBucket
  }

  private static func bucket(for offset: CGFloat) -> Int {
    Int((offset / bucketSize).rounded(.down))
  }
}

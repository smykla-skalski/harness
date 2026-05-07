import SwiftUI

struct SessionTimelineScrollBoundaryState: Equatable {
  static let triggerDistance: CGFloat = 220
  private static let bucketSize: CGFloat = SessionTimelineSectionPresentation.rowHeightEstimate

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
    enteredEdge(topBucket, from: oldValue.topBucket, towardEdge: <)
  }

  func enteredBottomEdge(from oldValue: Self) -> Bool {
    enteredEdge(bottomBucket, from: oldValue.bottomBucket, towardEdge: >)
  }

  func shouldTrack(from oldValue: Self) -> Bool {
    shouldTrackEdge(topBucket, from: oldValue.topBucket, towardEdge: <)
      || shouldTrackEdge(bottomBucket, from: oldValue.bottomBucket, towardEdge: >)
  }

  private func enteredEdge(
    _ newBucket: Int?,
    from oldBucket: Int?,
    towardEdge: (Int, Int) -> Bool
  ) -> Bool {
    guard let newBucket else {
      return false
    }
    guard let oldBucket else {
      return true
    }
    return towardEdge(newBucket, oldBucket)
  }

  private func shouldTrackEdge(
    _ newBucket: Int?,
    from oldBucket: Int?,
    towardEdge: (Int, Int) -> Bool
  ) -> Bool {
    switch (oldBucket, newBucket) {
    case (nil, nil):
      false
    case (.some, nil), (nil, .some):
      true
    case (.some(let oldBucket), .some(let newBucket)):
      towardEdge(newBucket, oldBucket)
    }
  }

  private static func bucket(for offset: CGFloat) -> Int {
    Int((offset / bucketSize).rounded(.down))
  }
}

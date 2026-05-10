import SwiftUI

struct SessionTimelineScrollBoundaryState: Equatable {
  static let triggerDistance: CGFloat = 220
  private static let bucketSize: CGFloat = SessionTimelineSectionPresentation.rowHeightEstimate

  private let topBucket: Int?
  private let bottomBucket: Int?
  private let topBufferDeficit: Int
  private let bottomBufferDeficit: Int

  static var triggerBufferRowCount: Int {
    max(1, Int(ceil(triggerDistance / bucketSize)))
  }

  var isNearTopEdge: Bool {
    topBucket != nil
  }

  var isNearBottomEdge: Bool {
    bottomBucket != nil
  }

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
    let topDistance = max(0, visibleMinY)
    if visibleMinY <= Self.triggerDistance {
      topBucket = Self.bucket(for: visibleMinY)
      topBufferDeficit = Self.bufferDeficitRows(distanceFromEdge: topDistance)
    } else {
      topBucket = nil
      topBufferDeficit = 0
    }
    let bottomDistance = max(0, contentHeight - visibleMaxY)
    bottomBucket =
      bottomDistance <= Self.triggerDistance
      ? Self.bucket(for: visibleMaxY)
      : nil
    bottomBufferDeficit =
      bottomDistance <= Self.triggerDistance
      ? Self.bufferDeficitRows(distanceFromEdge: bottomDistance)
      : 0
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

  func topEdgeAdvance(from oldValue: Self) -> Int {
    edgeAdvance(topBucket, from: oldValue.topBucket, towardEdge: <)
  }

  func bottomEdgeAdvance(from oldValue: Self) -> Int {
    edgeAdvance(bottomBucket, from: oldValue.bottomBucket, towardEdge: >)
  }

  func topEdgeBufferDeficitRows() -> Int {
    topBufferDeficit
  }

  func bottomEdgeBufferDeficitRows() -> Int {
    bottomBufferDeficit
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

  private func edgeAdvance(
    _ newBucket: Int?,
    from oldBucket: Int?,
    towardEdge: (Int, Int) -> Bool
  ) -> Int {
    guard let newBucket else {
      return 0
    }
    guard let oldBucket else {
      return 1
    }
    guard towardEdge(newBucket, oldBucket) else {
      return 0
    }
    return max(1, abs(newBucket - oldBucket))
  }

  private static func bucket(for offset: CGFloat) -> Int {
    Int((offset / bucketSize).rounded(.down))
  }

  private static func bufferDeficitRows(distanceFromEdge: CGFloat) -> Int {
    let remainingRows = max(0, Int((distanceFromEdge / bucketSize).rounded(.down)))
    return max(1, triggerBufferRowCount - remainingRows)
  }
}

import CoreGraphics

/// Variable-height row layout for the diff canvas once inline conversation
/// cards are interleaved between diff lines. Every diff row keeps the fixed
/// `rowHeight`; a row that owns a visible thread card reserves an extra
/// `cardHeight` gap directly below it for the hosted SwiftUI card.
///
/// Pure and value-typed so the row<->Y mapping that drives draw-culling and
/// hit-testing is unit-tested without instantiating an NSView. Offsets are
/// precomputed as a prefix sum in `init`, so every lookup is O(1) except the
/// inverse `rowIndex(atY:)` which is O(log n).
struct DashboardReviewFileDiffThreadLayout: Equatable {
  let rowHeight: CGFloat
  let rowCount: Int
  let totalHeight: CGFloat

  private let cardHeights: [Int: CGFloat]
  /// `prefixCardHeight[i]` = sum of card heights reserved for rows `< i`.
  private let prefixCardHeight: [CGFloat]
  private let trailingPadding: CGFloat

  init(
    rowCount: Int,
    rowHeight: CGFloat,
    cardHeights: [Int: CGFloat] = [:],
    trailingPadding: CGFloat = 2
  ) {
    let count = max(rowCount, 0)
    let resolvedRowHeight = max(rowHeight, 1)
    self.rowCount = count
    self.rowHeight = resolvedRowHeight
    self.cardHeights = cardHeights
    self.trailingPadding = trailingPadding
    var prefix = [CGFloat](repeating: 0, count: count + 1)
    var running: CGFloat = 0
    for index in 0..<count {
      prefix[index] = running
      running += max(cardHeights[index] ?? 0, 0)
    }
    prefix[count] = running
    prefixCardHeight = prefix
    totalHeight = CGFloat(max(count, 1)) * resolvedRowHeight + running + trailingPadding
  }

  /// Top Y of the row's diff text line.
  func rowTop(_ index: Int) -> CGFloat {
    let clamped = min(max(index, 0), rowCount)
    return CGFloat(clamped) * rowHeight + prefixCardHeight[clamped]
  }

  /// Rect of the diff text row (excluding any card gap below it).
  func rowRect(_ index: Int, width: CGFloat) -> CGRect {
    CGRect(x: 0, y: rowTop(index), width: width, height: rowHeight)
  }

  func hasCard(_ index: Int) -> Bool {
    (cardHeights[index] ?? 0) > 0
  }

  /// Rect of the hosted card gap directly below the row, or `nil` if the row
  /// owns no visible thread card.
  func cardRect(_ index: Int, width: CGFloat) -> CGRect? {
    guard let height = cardHeights[index], height > 0 else { return nil }
    return CGRect(x: 0, y: rowTop(index) + rowHeight, width: width, height: height)
  }

  /// Row index whose text line OR card gap contains `y`, clamped to range.
  /// O(log n) binary search over the precomputed row tops.
  func rowIndex(atY y: CGFloat) -> Int {
    guard rowCount > 0 else { return 0 }
    var low = 0
    var high = rowCount - 1
    var result = 0
    while low <= high {
      let mid = (low + high) / 2
      if rowTop(mid) <= y {
        result = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return result
  }

  /// Row index only when `y` lands on the row's diff text line (not its card
  /// gap); `nil` inside a card gap so clicks there fall through to the host.
  func rowIndexHittingTextLine(atY y: CGFloat) -> Int? {
    guard rowCount > 0 else { return nil }
    let index = rowIndex(atY: y)
    let top = rowTop(index)
    return (y >= top && y < top + rowHeight) ? index : nil
  }

  /// Inclusive row index range whose text lines or card gaps overlap `rect`.
  func visibleRowRange(in rect: CGRect) -> ClosedRange<Int>? {
    guard rowCount > 0 else { return nil }
    let first = max(rowIndex(atY: rect.minY), 0)
    let last = min(rowIndex(atY: rect.maxY), rowCount - 1)
    guard first <= last else { return nil }
    return first...last
  }
}

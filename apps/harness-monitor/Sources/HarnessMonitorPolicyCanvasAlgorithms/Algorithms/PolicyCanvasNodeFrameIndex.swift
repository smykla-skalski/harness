import CoreGraphics

/// A static uniform-grid broad phase over node frames. Body-hit and terminal
/// passes test each route against the node bodies it could possibly cross; a
/// brute-force scan is O(edges x nodes) and the repair chain runs it hundreds of
/// times, so on the extreme samples it dominated first paint. The grid lets a
/// route query only the nodes whose frame shares a cell with the route's bounds.
///
/// Equivalence is exact, not approximate: every segment of a route lies inside
/// the route's bounding box, so a node frame disjoint from that box cannot
/// intersect any segment. The grid therefore only drops guaranteed non-hits; the
/// caller still runs the same exact intersection test on the returned
/// candidates, so the resulting violation set is identical to the full scan.
///
/// Built once over a fixed node set and queried many times. A per-query visited
/// stamp dedups candidates that span several cells without allocating a set per
/// query.
final class PolicyCanvasNodeFrameIndex {
  private let cellSize: CGFloat
  private let originX: CGFloat
  private let originY: CGFloat
  private let columns: Int
  private let rows: Int
  private let cells: [[Int]]
  let nodeIDs: [String]
  let frames: [CGRect]
  private var visitStamp: [Int]
  private var currentStamp: Int = 0

  init(framesByID: [String: CGRect]) {
    let entries = framesByID.sorted { $0.key < $1.key }
    let ids = entries.map(\.key)
    let rects = entries.map(\.value)
    nodeIDs = ids
    frames = rects
    visitStamp = Array(repeating: 0, count: rects.count)

    guard let first = rects.first else {
      cellSize = 1
      originX = 0
      originY = 0
      columns = 0
      rows = 0
      cells = []
      return
    }

    var minX = first.minX
    var minY = first.minY
    var maxX = first.maxX
    var maxY = first.maxY
    var dimensionTotal: CGFloat = 0
    for frame in rects {
      minX = min(minX, frame.minX)
      minY = min(minY, frame.minY)
      maxX = max(maxX, frame.maxX)
      maxY = max(maxY, frame.maxY)
      dimensionTotal += max(frame.width, frame.height)
    }
    let averageDimension = dimensionTotal / CGFloat(rects.count)
    let resolvedCellSize = max(averageDimension, 1)
    cellSize = resolvedCellSize
    originX = minX
    originY = minY
    let columnCount = max(1, Int((maxX - minX) / resolvedCellSize) + 1)
    let rowCount = max(1, Int((maxY - minY) / resolvedCellSize) + 1)
    columns = columnCount
    rows = rowCount

    var buckets = Array(repeating: [Int](), count: columnCount * rowCount)
    for (ordinal, frame) in rects.enumerated() {
      let columnRange = Self.cellRange(
        lower: frame.minX, upper: frame.maxX,
        origin: minX, cellSize: resolvedCellSize, count: columnCount
      )
      let rowRange = Self.cellRange(
        lower: frame.minY, upper: frame.maxY,
        origin: minY, cellSize: resolvedCellSize, count: rowCount
      )
      for row in rowRange {
        let base = row * columnCount
        for column in columnRange {
          buckets[base + column].append(ordinal)
        }
      }
    }
    cells = buckets
  }

  /// Invoke `body` once for every node frame whose cell footprint overlaps
  /// `rect`, skipping any id in `exclude`. Candidates are a superset of the
  /// frames that truly intersect `rect`; the caller applies the exact test.
  func forEachCandidate(
    overlapping rect: CGRect,
    exclude: Set<String>,
    _ body: (_ nodeID: String, _ frame: CGRect) -> Void
  ) {
    guard !cells.isEmpty, !rect.isNull else {
      return
    }
    currentStamp += 1
    let stamp = currentStamp
    let columnRange = Self.cellRange(
      lower: rect.minX, upper: rect.maxX,
      origin: originX, cellSize: cellSize, count: columns
    )
    let rowRange = Self.cellRange(
      lower: rect.minY, upper: rect.maxY,
      origin: originY, cellSize: cellSize, count: rows
    )
    for row in rowRange {
      let base = row * columns
      for column in columnRange {
        for ordinal in cells[base + column] {
          guard visitStamp[ordinal] != stamp else {
            continue
          }
          visitStamp[ordinal] = stamp
          let nodeID = nodeIDs[ordinal]
          guard !exclude.contains(nodeID) else {
            continue
          }
          body(nodeID, frames[ordinal])
        }
      }
    }
  }

  private static func cellRange(
    lower: CGFloat,
    upper: CGFloat,
    origin: CGFloat,
    cellSize: CGFloat,
    count: Int
  ) -> ClosedRange<Int> {
    let lowerCell = Int((lower - origin) / cellSize)
    let upperCell = Int((upper - origin) / cellSize)
    let clampedLower = min(max(lowerCell, 0), count - 1)
    let clampedUpper = min(max(upperCell, 0), count - 1)
    return min(clampedLower, clampedUpper)...max(clampedLower, clampedUpper)
  }
}

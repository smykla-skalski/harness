enum DashboardReviewFileDiffThreadMap {
  static func build(
    rows: [DashboardReviewFileDiffRow],
    threads: [DashboardReviewFileThreadAnchor]
  ) -> [Int: [DashboardReviewFileThreadAnchor]] {
    guard !threads.isEmpty else { return [:] }
    let index = RowMatchIndex(threads: threads)
    var out: [Int: [DashboardReviewFileThreadAnchor]] = [:]
    out.reserveCapacity(min(rows.count, threads.count))
    for row in rows {
      let matched = index.threads(for: row)
      if !matched.isEmpty {
        out[row.id] = matched
      }
    }
    return out
  }
}

private struct RowMatchIndex {
  private let threadsByDiffPosition: [Int: [DashboardReviewFileThreadAnchor]]
  private let threadsByOldLine: [Int: [DashboardReviewFileThreadAnchor]]
  private let threadsByNewLine: [Int: [DashboardReviewFileThreadAnchor]]
  private let threadsByAnyLine: [Int: [DashboardReviewFileThreadAnchor]]
  private let orderByID: [String: Int]

  init(threads: [DashboardReviewFileThreadAnchor]) {
    var byDiffPosition: [Int: [DashboardReviewFileThreadAnchor]] = [:]
    var byOldLine: [Int: [DashboardReviewFileThreadAnchor]] = [:]
    var byNewLine: [Int: [DashboardReviewFileThreadAnchor]] = [:]
    var byAnyLine: [Int: [DashboardReviewFileThreadAnchor]] = [:]
    var order: [String: Int] = [:]
    order.reserveCapacity(threads.count)

    for (offset, thread) in threads.enumerated() {
      order[thread.id] = offset
      if let position = thread.diffPosition {
        byDiffPosition[position, default: []].append(thread)
      }
      guard let line = thread.line else { continue }
      switch thread.side {
      case .old:
        byOldLine[line, default: []].append(thread)
      case .new:
        byNewLine[line, default: []].append(thread)
      case nil:
        byAnyLine[line, default: []].append(thread)
      }
    }

    threadsByDiffPosition = byDiffPosition
    threadsByOldLine = byOldLine
    threadsByNewLine = byNewLine
    threadsByAnyLine = byAnyLine
    orderByID = order
  }

  func threads(for row: DashboardReviewFileDiffRow) -> [DashboardReviewFileThreadAnchor] {
    var matched: [DashboardReviewFileThreadAnchor] = []
    var seen = Set<String>()

    if let diffPosition = row.diffPosition {
      append(threadsByDiffPosition[diffPosition], to: &matched, seen: &seen)
    }
    appendLineThreads(for: row, to: &matched, seen: &seen)

    if matched.count > 1 {
      matched.sort { lhs, rhs in
        (orderByID[lhs.id] ?? .max) < (orderByID[rhs.id] ?? .max)
      }
    }
    return matched
  }

  private func appendLineThreads(
    for row: DashboardReviewFileDiffRow,
    to matched: inout [DashboardReviewFileThreadAnchor],
    seen: inout Set<String>
  ) {
    if let oldLine = row.oldLine {
      append(threadsByOldLine[oldLine], to: &matched, seen: &seen)
      append(threadsByAnyLine[oldLine], to: &matched, seen: &seen)
    }
    if let newLine = row.newLine {
      append(threadsByNewLine[newLine], to: &matched, seen: &seen)
      if row.oldLine != newLine {
        append(threadsByAnyLine[newLine], to: &matched, seen: &seen)
      }
    }
  }

  private func append(
    _ candidates: [DashboardReviewFileThreadAnchor]?,
    to matched: inout [DashboardReviewFileThreadAnchor],
    seen: inout Set<String>
  ) {
    guard let candidates else { return }
    for candidate in candidates where seen.insert(candidate.id).inserted {
      matched.append(candidate)
    }
  }
}

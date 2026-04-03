import SwiftUI

struct HarnessMonitorWrapLayout: Layout {
  struct Cache {
    var rows: [HarnessMonitorWrapLayoutRow] = []
    var signature: Signature?
  }

  struct Signature: Equatable {
    let intrinsicSizes: [CGSize]
    let maxWidth: CGFloat
  }

  let spacing: CGFloat
  let lineSpacing: CGFloat

  init(spacing: CGFloat = 8, lineSpacing: CGFloat? = nil) {
    self.spacing = spacing
    self.lineSpacing = lineSpacing ?? spacing
  }

  func makeCache(subviews _: Subviews) -> Cache {
    Cache()
  }

  func updateCache(_ cache: inout Cache, subviews _: Subviews) {
    cache = Cache()
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) -> CGSize {
    let rows = arrangedRows(
      maxWidth: proposal.width ?? .greatestFiniteMagnitude,
      subviews: subviews,
      cache: &cache
    )

    guard !rows.isEmpty else {
      return .zero
    }

    let width =
      proposal.width
      ?? rows.map(\.width).max()
      ?? 0
    let totalHeight =
      rows.map(\.height).reduce(0, +)
      + CGFloat(max(rows.count - 1, 0)) * lineSpacing

    return CGSize(width: width, height: totalHeight)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) {
    let rows = arrangedRows(
      maxWidth: bounds.width,
      subviews: subviews,
      cache: &cache
    )
    var y = bounds.minY

    for row in rows {
      var x = bounds.minX

      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: x, y: y),
          anchor: .topLeading,
          proposal: ProposedViewSize(item.size)
        )
        x += item.size.width + spacing
      }

      y += row.height + lineSpacing
    }
  }

  private func arrangedRows(
    maxWidth: CGFloat,
    subviews: Subviews,
    cache: inout Cache
  ) -> [HarnessMonitorWrapLayoutRow] {
    guard !subviews.isEmpty else {
      return []
    }

    let clampedWidth =
      maxWidth.isFinite && maxWidth > 0
      ? maxWidth
      : .greatestFiniteMagnitude
    let intrinsicSizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let signature = Signature(
      intrinsicSizes: intrinsicSizes,
      maxWidth: clampedWidth
    )
    if cache.signature == signature {
      return cache.rows
    }

    var rows: [HarnessMonitorWrapLayoutRow] = []
    var currentItems: [HarnessMonitorWrapLayoutItem] = []
    var currentWidth: CGFloat = 0
    var currentHeight: CGFloat = 0

    for index in subviews.indices {
      let itemSize = measuredSize(
        for: subviews[index],
        intrinsicSize: intrinsicSizes[index],
        maxWidth: clampedWidth
      )
      let proposedWidth =
        currentItems.isEmpty
        ? itemSize.width
        : currentWidth + spacing + itemSize.width

      if !currentItems.isEmpty && proposedWidth > clampedWidth {
        rows.append(
          HarnessMonitorWrapLayoutRow(
            items: currentItems,
            width: currentWidth,
            height: currentHeight
          )
        )
        currentItems = []
        currentWidth = 0
        currentHeight = 0
      }

      currentItems.append(
        HarnessMonitorWrapLayoutItem(
          index: index,
          size: itemSize
        )
      )
      currentWidth =
        currentItems.count == 1
        ? itemSize.width
        : currentWidth + spacing + itemSize.width
      currentHeight = max(currentHeight, itemSize.height)
    }

    if !currentItems.isEmpty {
      rows.append(
        HarnessMonitorWrapLayoutRow(
          items: currentItems,
          width: currentWidth,
          height: currentHeight
        )
      )
    }

    cache.signature = signature
    cache.rows = rows
    return rows
  }

  private func measuredSize(
    for subview: LayoutSubview,
    intrinsicSize: CGSize,
    maxWidth: CGFloat
  ) -> CGSize {
    guard intrinsicSize.width > maxWidth else {
      return intrinsicSize
    }

    return subview.sizeThatFits(
      ProposedViewSize(width: maxWidth, height: nil)
    )
  }
}

struct HarnessMonitorWrapLayoutRow {
  let items: [HarnessMonitorWrapLayoutItem]
  let width: CGFloat
  let height: CGFloat
}

struct HarnessMonitorWrapLayoutItem {
  let index: Int
  let size: CGSize
}

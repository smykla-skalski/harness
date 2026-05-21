import AppKit
import SwiftUI

struct HarnessMarkdownInlineFlowView: View {
  enum ImageLayout {
    case body
    case inline
  }

  let inlines: [HarnessMarkdownInline]
  let style: HarnessMarkdownInlineRenderStyle
  let images: HarnessMarkdownImageSettings
  var imageLayout: ImageLayout = .body

  var body: some View {
    if usesFragmentLayout {
      HarnessMarkdownInlineWrapLayout(horizontalSpacing: 0, verticalSpacing: 2) {
        ForEach(Array(inlines.enumerated()), id: \.offset) { _, inline in
          HarnessMarkdownInlineFragmentView(
            inline: inline,
            style: style,
            images: images,
            imageLayout: imageLayout,
            preferBlockImage: imageLayout == .body && inlines.isStandaloneMarkdownImage
          )
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .alignmentGuide(.firstTextBaseline) { dimensions in
        inlines.isStandaloneMarkdownImage
          ? dimensions[VerticalAlignment.center]
          : dimensions[VerticalAlignment.firstTextBaseline]
      }
    } else {
      Text(HarnessMarkdownInlineRenderer.attributedString(from: inlines, style: style))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var usesFragmentLayout: Bool {
    inlines.containsMarkdownImage || inlines.containsMarkdownLink
  }
}

private struct HarnessMarkdownInlineFragmentView: View {
  let inline: HarnessMarkdownInline
  let style: HarnessMarkdownInlineRenderStyle
  let images: HarnessMarkdownImageSettings
  let imageLayout: HarnessMarkdownInlineFlowView.ImageLayout
  let preferBlockImage: Bool

  var body: some View {
    switch inline {
    case .emphasis(let children):
      HarnessMarkdownInlineFlowView(
        inlines: children,
        style: style.withFont(style.font.italic()),
        images: images,
        imageLayout: .inline
      )
    case .image(let image):
      HarnessMarkdownRemoteImageView(
        image: image,
        style: style,
        settings: images,
        usesBlockSizing: preferBlockImage
      )
    case .link(let label, let destination, _):
      link(label: label, destination: destination)
    case .strikethrough(let children):
      HarnessMarkdownInlineFlowView(
        inlines: children, style: style, images: images, imageLayout: .inline
      )
      .strikethrough()
    case .strong(let children):
      HarnessMarkdownInlineFlowView(
        inlines: children,
        style: style.withFont(style.font.bold()),
        images: images,
        imageLayout: .inline
      )
    case .autolink(let destination):
      link(label: [.text(destination)], destination: destination)
    case .code, .lineBreak, .softBreak, .text:
      Text(HarnessMarkdownInlineRenderer.attributedString(from: [inline], style: style))
    }
  }

  @ViewBuilder
  private func link(label: [HarnessMarkdownInline], destination: String) -> some View {
    if label.containsMarkdownImage, let url = URL(string: decodeEntities(destination)) {
      Link(destination: url) {
        HarnessMarkdownInlineFlowView(
          inlines: label,
          style: style,
          images: images,
          imageLayout: preferBlockImage ? imageLayout : .inline
        )
      }
      .modifier(HarnessMarkdownLinkHoverModifier(color: style.colors.link))
    } else if let url = URL(string: decodeEntities(destination)) {
      Link(destination: url) {
        HarnessMarkdownInlineFlowView(
          inlines: label,
          style: style.withMarkdownTextColor(style.colors.link),
          images: images,
          imageLayout: .inline
        )
      }
      .underline()
      .modifier(HarnessMarkdownLinkHoverModifier(color: style.colors.link))
    } else {
      Text(
        HarnessMarkdownInlineRenderer.attributedString(
          from: [.link(label: label, destination: destination, title: nil)], style: style)
      )
    }
  }
}

private struct HarnessMarkdownInlineWrapLayout: Layout {
  let horizontalSpacing: CGFloat
  let verticalSpacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    measuredRows(in: proposal.width, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    for row in measuredRows(in: bounds.width, subviews: subviews).rows {
      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
          proposal: ProposedViewSize(item.size)
        )
      }
    }
  }

  private func measuredRows(in width: CGFloat?, subviews: Subviews) -> (
    rows: [HarnessMarkdownInlineLayoutRow], size: CGSize
  ) {
    let maxWidth = width ?? .greatestFiniteMagnitude
    var rows: [HarnessMarkdownInlineLayoutRow] = []
    var items: [HarnessMarkdownInlineLayoutItem] = []
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalWidth: CGFloat = 0
    var y: CGFloat = 0

    func finishRow() {
      guard !items.isEmpty else { return }
      rows.append(HarnessMarkdownInlineLayoutRow(items: items, y: y, height: rowHeight))
      totalWidth = max(totalWidth, rowWidth)
      y += rowHeight + verticalSpacing
      items.removeAll(keepingCapacity: true)
      rowWidth = 0
      rowHeight = 0
    }

    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(
        ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)
      )
      let spacing = items.isEmpty ? 0 : horizontalSpacing
      if !items.isEmpty, rowWidth + spacing + size.width > maxWidth {
        finishRow()
      }
      let x = items.isEmpty ? 0 : rowWidth + horizontalSpacing
      items.append(HarnessMarkdownInlineLayoutItem(index: index, x: x, size: size))
      rowWidth = x + size.width
      rowHeight = max(rowHeight, size.height)
    }
    finishRow()
    return (rows, CGSize(width: totalWidth, height: max(0, y - verticalSpacing)))
  }
}

private struct HarnessMarkdownInlineLayoutRow {
  let items: [HarnessMarkdownInlineLayoutItem]
  let y: CGFloat
  let height: CGFloat
}

private struct HarnessMarkdownInlineLayoutItem {
  let index: Int
  let x: CGFloat
  let size: CGSize
}

private struct HarnessMarkdownLinkHoverModifier: ViewModifier {
  let color: Color
  @State private var isHovering = false

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .background {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(color.opacity(isHovering ? 0.14 : 0))
      }
      .onHover { hovering in
        guard isHovering != hovering else { return }
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
      .onDisappear {
        if isHovering {
          NSCursor.pop()
          isHovering = false
        }
      }
  }
}

private struct HarnessMarkdownRemoteImageView: View {
  let image: HarnessMarkdownImage
  let style: HarnessMarkdownInlineRenderStyle
  let settings: HarnessMarkdownImageSettings
  let usesBlockSizing: Bool

  @State private var loadedImage: NSImage?
  @State private var failed = false

  var body: some View {
    Group {
      if let loadedImage {
        loadedImageView(loadedImage)
      } else if failed {
        fallbackLabel
      } else {
        ProgressView()
          .controlSize(.small)
          .frame(height: min(settings.maxInlineHeight, imageHeight))
      }
    }
    .task(id: image.source) {
      await loadImage()
    }
    .help(image.title ?? image.alt)
    .alignmentGuide(.firstTextBaseline) { dimensions in
      dimensions[VerticalAlignment.center]
    }
  }

  private var imageHeight: CGFloat {
    usesBlockSizing ? settings.maxBlockHeight : settings.maxInlineHeight
  }

  @ViewBuilder
  private func loadedImageView(_ loadedImage: NSImage) -> some View {
    let image = Image(nsImage: loadedImage)
      .resizable()
      .interpolation(.high)
      .scaledToFit()

    if usesBlockSizing {
      image
        .frame(maxHeight: imageHeight)
        .clipShape(
          RoundedRectangle(cornerRadius: settings.cornerRadius, style: .continuous))
    } else {
      image
        .frame(height: imageHeight, alignment: .center)
        .clipShape(
          RoundedRectangle(cornerRadius: settings.cornerRadius, style: .continuous))
    }
  }

  private var fallbackLabel: some View {
    Text(verbatim: image.alt.isEmpty ? image.source : image.alt)
      .font(style.font)
      .foregroundStyle(style.colors.link)
      .underline()
  }

  @MainActor
  private func loadImage() async {
    guard loadedImage == nil, !image.source.isEmpty else { return }
    guard let url = URL(string: image.source), url.scheme != nil else {
      failed = true
      return
    }
    do {
      let data = try await HarnessMarkdownImageDataCache.shared.data(for: url)
      guard let nsImage = NSImage(data: data) else {
        failed = true
        return
      }
      loadedImage = nsImage
      failed = false
    } catch {
      failed = true
    }
  }
}

private actor HarnessMarkdownImageDataCache {
  static let shared = HarnessMarkdownImageDataCache()

  private var values: [URL: Data] = [:]
  private var order: [URL] = []
  private let capacity = 64

  func data(for url: URL) async throws -> Data {
    if let cached = values[url] { return cached }
    let (data, _) = try await URLSession.shared.data(from: url)
    values[url] = data
    order.append(url)
    if order.count > capacity {
      let removed = order.removeFirst()
      values.removeValue(forKey: removed)
    }
    return data
  }
}

extension HarnessMarkdownInline {
  fileprivate var containsMarkdownLink: Bool {
    switch self {
    case .autolink, .link:
      true
    case .emphasis(let children), .strikethrough(let children), .strong(let children):
      children.containsMarkdownLink
    case .code, .image, .lineBreak, .softBreak, .text:
      false
    }
  }
}

extension [HarnessMarkdownInline] {
  fileprivate var containsMarkdownLink: Bool {
    contains { $0.containsMarkdownLink }
  }
}

extension HarnessMarkdownInlineRenderStyle {
  fileprivate func withMarkdownTextColor(_ color: Color) -> HarnessMarkdownInlineRenderStyle {
    var updatedColors = colors
    updatedColors.text = color
    return HarnessMarkdownInlineRenderStyle(font: font, codeFont: codeFont, colors: updatedColors)
  }
}

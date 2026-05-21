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
    if inlines.containsMarkdownImage {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
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
    } else {
      Text(HarnessMarkdownInlineRenderer.attributedString(from: inlines, style: style))
        .fixedSize(horizontal: false, vertical: true)
    }
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
    case .autolink, .code, .lineBreak, .softBreak, .text:
      Text(HarnessMarkdownInlineRenderer.attributedString(from: [inline], style: style))
    }
  }

  @ViewBuilder
  private func link(label: [HarnessMarkdownInline], destination: String) -> some View {
    if label.containsMarkdownImage, let url = URL(string: destination) {
      Link(destination: url) {
        HarnessMarkdownInlineFlowView(
          inlines: label,
          style: style,
          images: images,
          imageLayout: preferBlockImage ? imageLayout : .inline
        )
      }
      .buttonStyle(.plain)
    } else {
      Text(
        HarnessMarkdownInlineRenderer.attributedString(
          from: [.link(label: label, destination: destination, title: nil)], style: style)
      )
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
        Image(nsImage: loadedImage)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(maxHeight: imageHeight)
          .clipShape(
            RoundedRectangle(cornerRadius: settings.cornerRadius, style: .continuous))
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
  }

  private var imageHeight: CGFloat {
    usesBlockSizing ? settings.maxBlockHeight : settings.maxInlineHeight
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

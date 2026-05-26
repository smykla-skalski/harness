import AppKit
import SwiftUI

struct DashboardOCRImagePreviewItem: Identifiable {
  let id: UUID
  let image: NSImage
  let title: String
  let subtitle: String?

  init(item: DashboardOCRImageItem) {
    id = item.id
    image = item.image
    title = item.sourceName
    subtitle = item.sourceDetail
  }

  var imageSize: CGSize {
    CGSize(
      width: max(1, image.size.width),
      height: max(1, image.size.height)
    )
  }

  var idealWindowSize: CGSize {
    let visibleFrame =
      NSScreen.main?.visibleFrame.size
      ?? CGSize(width: 1_280, height: 820)
    return CGSize(
      width: max(1, visibleFrame.width),
      height: max(1, visibleFrame.height)
    )
  }

  func displaySize(fitting availableSize: CGSize) -> CGSize {
    let scale = min(
      1,
      availableSize.width / imageSize.width,
      availableSize.height / imageSize.height
    )
    return CGSize(
      width: imageSize.width * scale,
      height: imageSize.height * scale
    )
  }
}

struct DashboardOCRImagePreviewSheet: View {
  let item: DashboardOCRImagePreviewItem
  @Environment(\.dismiss)
  private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      imageScrollView
    }
    .frame(
      width: item.idealWindowSize.width,
      height: item.idealWindowSize.height
    )
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
          .scaledFont(.headline.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        if let subtitle = item.subtitle {
          Text(subtitle)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer()
      Button("Done") {
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingXL)
    .padding(.vertical, HarnessMonitorTheme.spacingLG)
  }

  private var imageScrollView: some View {
    GeometryReader { proxy in
      let padding = HarnessMonitorTheme.spacingXL
      let displaySize = item.displaySize(
        fitting: CGSize(
          width: max(1, proxy.size.width - padding * 2),
          height: max(1, proxy.size.height - padding * 2)
        )
      )
      ScrollView([.horizontal, .vertical]) {
        Image(nsImage: item.image)
          .resizable()
          .interpolation(.high)
          .frame(width: displaySize.width, height: displaySize.height)
          .padding(padding)
          .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(HarnessMonitorTheme.ink.opacity(0.035))
  }
}

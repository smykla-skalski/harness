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
    CGSize(
      width: min(max(720, imageSize.width + 64), 1_280),
      height: min(max(520, imageSize.height + 132), 920)
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
      minWidth: 720,
      idealWidth: item.idealWindowSize.width,
      minHeight: 520,
      idealHeight: item.idealWindowSize.height
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
    ScrollView([.horizontal, .vertical]) {
      Image(nsImage: item.image)
        .resizable()
        .interpolation(.high)
        .frame(width: item.imageSize.width, height: item.imageSize.height)
        .padding(HarnessMonitorTheme.spacingXL)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(HarnessMonitorTheme.ink.opacity(0.035))
  }
}

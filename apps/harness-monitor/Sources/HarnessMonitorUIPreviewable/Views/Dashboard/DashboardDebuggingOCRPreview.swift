import AppKit
import SwiftUI

struct DashboardOCRImagePreviewItem: Identifiable {
  let id: UUID
  let image: NSImage
  let title: String
  let subtitle: String?
  let recognizedText: String

  init(item: DashboardOCRImageItem) {
    id = item.id
    image = item.image
    title = item.sourceName
    subtitle = nil
    recognizedText = item.recognizedText
  }

  init(recentImage: DashboardOCRRecentImage) {
    id = UUID()
    image = recentImage.image
    title = recentImage.sourceName
    subtitle = "Saved \(recentImage.storedAt.formatted(date: .abbreviated, time: .shortened))"
    recognizedText = recentImage.recognizedText
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
    return idealWindowSize(fitting: visibleFrame)
  }

  func idealWindowSize(fitting visibleSize: CGSize) -> CGSize {
    let textHeight =
      recognizedText.isEmpty
      ? 0
      : DashboardOCRImagePreviewLayout.recognizedTextHeight
        + DashboardOCRImagePreviewLayout.dividerHeight
    let maxImageArea = CGSize(
      width: max(1, visibleSize.width - DashboardOCRImagePreviewLayout.imagePadding * 2),
      height: max(
        1,
        visibleSize.height - DashboardOCRImagePreviewLayout.headerHeight - textHeight
          - DashboardOCRImagePreviewLayout.imagePadding * 2
      )
    )
    let imageDisplaySize = displaySize(fitting: maxImageArea)
    return CGSize(
      width: min(
        visibleSize.width,
        max(
          DashboardOCRImagePreviewLayout.minimumWidth,
          imageDisplaySize.width + DashboardOCRImagePreviewLayout.imagePadding * 2
        )
      ),
      height: min(
        visibleSize.height,
        DashboardOCRImagePreviewLayout.headerHeight + textHeight + imageDisplaySize.height
          + DashboardOCRImagePreviewLayout.imagePadding * 2
      )
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

private enum DashboardOCRImagePreviewLayout {
  static let dividerHeight: CGFloat = 1
  static let headerHeight: CGFloat = 76
  static let imagePadding: CGFloat = HarnessMonitorTheme.spacingXL
  static let minimumWidth: CGFloat = 320
  static let recognizedTextHeight: CGFloat = 180
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
      if !item.recognizedText.isEmpty {
        Divider()
        recognizedTextView
      }
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

  private var recognizedTextView: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("OCR Text")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      ScrollView {
        Text(item.recognizedText)
          .scaledFont(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .background(HarnessMonitorTheme.ink.opacity(0.04))
      .clipShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(height: DashboardOCRImagePreviewLayout.recognizedTextHeight)
  }
}

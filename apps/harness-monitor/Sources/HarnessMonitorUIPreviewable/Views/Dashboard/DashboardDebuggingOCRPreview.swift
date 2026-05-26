import AppKit
import SwiftUI

struct DashboardOCRImagePreviewItem: Identifiable {
  let id: UUID
  let image: NSImage
  let title: String
  let subtitle: String?
  let sourceMetadata: [DashboardOCRImageSourceMetadata]
  let recognizedText: String

  init(item: DashboardOCRImageItem) {
    id = item.id
    image = item.image
    title = item.sourceName
    subtitle = nil
    sourceMetadata = item.sourceMetadata
    recognizedText = item.recognizedText
  }

  init(recentImage: DashboardOCRRecentImage) {
    id = UUID()
    image = recentImage.image
    title = recentImage.sourceName
    subtitle = "Saved \(recentImage.storedAt.formatted(date: .abbreviated, time: .shortened))"
    sourceMetadata = recentImage.sourceMetadata
    recognizedText = recentImage.recognizedText
  }

  var imageSize: CGSize {
    CGSize(
      width: max(1, image.size.width),
      height: max(1, image.size.height)
    )
  }

  var copyableFilePaths: [String] {
    sourceMetadata.copyableFilePaths
  }

  var showsSourceDetails: Bool {
    !copyableFilePaths.isEmpty || sourceMetadata.count > 1
  }

  var idealWindowSize: CGSize {
    let visibleFrame =
      NSScreen.main?.visibleFrame.size
      ?? CGSize(width: 1_280, height: 820)
    return idealWindowSize(fitting: visibleFrame)
  }

  func idealWindowSize(fitting visibleSize: CGSize) -> CGSize {
    let supplementaryContentHeight = supplementaryContentHeight
    let maxImageArea = CGSize(
      width: max(1, visibleSize.width - DashboardOCRImagePreviewLayout.imagePadding * 2),
      height: max(
        1,
        visibleSize.height - DashboardOCRImagePreviewLayout.headerHeight
          - supplementaryContentHeight
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
        DashboardOCRImagePreviewLayout.headerHeight + supplementaryContentHeight
          + imageDisplaySize.height + DashboardOCRImagePreviewLayout.imagePadding * 2
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

  private var supplementaryContentHeight: CGFloat {
    var height: CGFloat = 0
    if showsSourceDetails {
      height += DashboardOCRImagePreviewLayout.dividerHeight
      height += DashboardOCRImagePreviewLayout.sourceDetailsSectionHeight(
        for: sourceMetadata
      )
    }
    if !recognizedText.isEmpty {
      height += DashboardOCRImagePreviewLayout.dividerHeight
      height += DashboardOCRImagePreviewLayout.recognizedTextSectionHeight(for: recognizedText)
    }
    return height
  }
}

private enum DashboardOCRImagePreviewLayout {
  static let dividerHeight: CGFloat = 1
  static let headerHeight: CGFloat = 76
  static let imagePadding: CGFloat = HarnessMonitorTheme.spacingXL
  static let minimumWidth: CGFloat = 320
  static let recognizedTextApproxCharactersPerLine = 96
  static let recognizedTextBodyMinimumHeight: CGFloat = 72
  static let recognizedTextBodyMaximumHeight: CGFloat = 220
  static let recognizedTextHeaderHeight: CGFloat = 18
  static let recognizedTextLineHeight: CGFloat = 18
  static let recognizedTextSectionPadding = HarnessMonitorTheme.spacingLG
  static let recognizedTextSpacing = HarnessMonitorTheme.spacingSM
  static let sourceDetailsHeaderHeight: CGFloat = 18
  static let sourceDetailsLineHeight: CGFloat = 34
  static let sourceDetailsMaximumBodyHeight: CGFloat = 118

  static func recognizedTextSectionHeight(for text: String) -> CGFloat {
    recognizedTextSectionPadding * 2 + recognizedTextHeaderHeight + recognizedTextSpacing
      + recognizedTextBodyHeight(for: text)
  }

  static func recognizedTextBodyHeight(for text: String) -> CGFloat {
    let estimatedLines = text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> Int in
        max(1, Int(ceil(Double(line.count) / Double(recognizedTextApproxCharactersPerLine))))
      }
      .reduce(0, +)
    let contentHeight =
      CGFloat(max(1, estimatedLines)) * recognizedTextLineHeight
      + HarnessMonitorTheme.spacingMD * 2
    return min(
      recognizedTextBodyMaximumHeight,
      max(recognizedTextBodyMinimumHeight, contentHeight)
    )
  }

  static func sourceDetailsSectionHeight(
    for metadata: [DashboardOCRImageSourceMetadata]
  ) -> CGFloat {
    recognizedTextSectionPadding * 2 + sourceDetailsHeaderHeight + recognizedTextSpacing
      + sourceDetailsBodyHeight(for: metadata)
  }

  static func sourceDetailsBodyHeight(
    for metadata: [DashboardOCRImageSourceMetadata]
  ) -> CGFloat {
    min(
      sourceDetailsMaximumBodyHeight,
      CGFloat(max(1, metadata.count)) * sourceDetailsLineHeight
    )
  }
}

struct DashboardOCRImagePreviewSheet: View {
  let item: DashboardOCRImagePreviewItem
  @Environment(\.dismiss)
  private var dismiss

  var body: some View {
    let sheetSize = item.idealWindowSize
    VStack(spacing: 0) {
      header
      Divider()
      imageScrollView
        .frame(height: imageViewportHeight(in: sheetSize))
      if item.showsSourceDetails {
        Divider()
        sourceDetailsView
      }
      if !item.recognizedText.isEmpty {
        Divider()
        recognizedTextView
      }
    }
    .frame(
      width: sheetSize.width,
      height: sheetSize.height
    )
  }

  private func imageViewportHeight(in sheetSize: CGSize) -> CGFloat {
    let sourceDetailsHeight =
      item.showsSourceDetails
      ? DashboardOCRImagePreviewLayout.sourceDetailsSectionHeight(
        for: item.sourceMetadata
      ) + DashboardOCRImagePreviewLayout.dividerHeight
      : 0
    let recognizedTextHeight =
      item.recognizedText.isEmpty
      ? 0
      : DashboardOCRImagePreviewLayout.recognizedTextSectionHeight(for: item.recognizedText)
        + DashboardOCRImagePreviewLayout.dividerHeight
    return max(
      1,
      sheetSize.height - DashboardOCRImagePreviewLayout.headerHeight
        - DashboardOCRImagePreviewLayout.dividerHeight - sourceDetailsHeight
        - recognizedTextHeight
    )
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
          .scaledFont(.headline.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(item.copyableFilePaths.first ?? item.title)
          .contextMenu {
            copyPathCommands
          }
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

  @ViewBuilder private var copyPathCommands: some View {
    if let primaryPath = item.copyableFilePaths.first {
      Button("Copy Path") {
        HarnessMonitorClipboard.copy(primaryPath)
      }
      if item.copyableFilePaths.count > 1 {
        Button("Copy All Paths") {
          HarnessMonitorClipboard.copy(item.copyableFilePaths.joined(separator: "\n"))
        }
      }
    } else {
      Text("No path available")
    }
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

  @ViewBuilder private var sourceDetailsView: some View {
    let bodyHeight = DashboardOCRImagePreviewLayout.sourceDetailsBodyHeight(
      for: item.sourceMetadata
    )
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack {
        Text("Sources")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer()
        if !item.copyableFilePaths.isEmpty {
          Button {
            HarnessMonitorClipboard.copy(item.copyableFilePaths.joined(separator: "\n"))
          } label: {
            Label("Copy Paths", systemImage: "doc.on.clipboard")
          }
          .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(item.sourceMetadata, id: \.key) { metadata in
            VStack(alignment: .leading, spacing: 2) {
              Text(metadata.name)
                .scaledFont(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
              if let detail = metadata.detail, !detail.isEmpty {
                Text(detail)
                  .scaledFont(.caption2.monospaced())
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .textSelection(.enabled)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(height: bodyHeight)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(
      height: DashboardOCRImagePreviewLayout.sourceDetailsSectionHeight(
        for: item.sourceMetadata
      )
    )
    .contextMenu {
      copyPathCommands
    }
  }

  @ViewBuilder private var recognizedTextView: some View {
    let bodyHeight = DashboardOCRImagePreviewLayout.recognizedTextBodyHeight(
      for: item.recognizedText
    )
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Scanned Text")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      ScrollView {
        Text(item.recognizedText)
          .scaledFont(.caption.monospaced())
          .textSelection(.enabled)
          .padding(HarnessMonitorTheme.spacingMD)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(height: bodyHeight)
      .background(HarnessMonitorTheme.ink.opacity(0.04))
      .clipShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(
      height: DashboardOCRImagePreviewLayout.recognizedTextSectionHeight(
        for: item.recognizedText
      )
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingOCRPreviewText)
  }
}

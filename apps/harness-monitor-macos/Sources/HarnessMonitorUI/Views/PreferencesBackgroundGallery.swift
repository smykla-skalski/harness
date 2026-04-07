import SwiftUI

struct PreferencesBackgroundGallery: View {
  @Binding var selection: String
  @Binding var backdropModeRawValue: String
  let selectedBackground: HarnessMonitorBackgroundSelection
  let collection: BackgroundCollection
  @ScaledMetric(relativeTo: .body) private var previewHeight = 96.0

  private var options: [HarnessMonitorBackgroundSelection] {
    switch collection {
    case .featured: HarnessMonitorBackgroundSelection.bundledLibrary
    case .native: HarnessMonitorBackgroundSelection.systemLibrary
    }
  }

  private let columns = [
    GridItem(.adaptive(minimum: 180, maximum: 220), spacing: HarnessMonitorTheme.spacingMD)
  ]

  var body: some View {
    if options.isEmpty {
      ContentUnavailableView(
        "No wallpapers found",
        systemImage: "photo",
        description: Text("macOS wallpapers were not found on this Mac")
      )
    } else {
      LazyVGrid(columns: columns, alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        ForEach(options) { background in
          PreferencesBackgroundTile(
            background: background,
            isSelected: background.storageValue == selectedBackground.storageValue,
            previewHeight: previewHeight,
            select: { select(background) }
          )
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesBackgroundGallery)
      .task(id: collection) {
        await BackgroundThumbnailCache.shared.prefetch(options)
      }
    }
  }

  private func select(_ background: HarnessMonitorBackgroundSelection) {
    selection = background.storageValue
    if HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) == HarnessMonitorBackdropMode.none {
      backdropModeRawValue = HarnessMonitorBackdropMode.window.rawValue
    }
  }
}

private struct PreferencesBackgroundTile: View {
  let background: HarnessMonitorBackgroundSelection
  let isSelected: Bool
  let previewHeight: CGFloat
  let select: () -> Void
  @State private var loadedImage: Image?

  private static let selectionRingWidth: CGFloat = 3

  private var outerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
  }

  var body: some View {
    Button(action: select) {
      ZStack(alignment: .topTrailing) {
        previewContent
          .frame(maxWidth: .infinity)
          .frame(height: isSelected ? previewHeight - 2 * Self.selectionRingWidth : previewHeight)
          .clipped()
          .clipShape(
            RoundedRectangle(
              cornerRadius: isSelected
                ? HarnessMonitorTheme.cornerRadiusLG - Self.selectionRingWidth
                : HarnessMonitorTheme.cornerRadiusLG,
              style: .continuous
            )
          )
          .padding(isSelected ? Self.selectionRingWidth : 0)

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(isSelected ? HarnessMonitorTheme.accent : .white.opacity(0.88))
          .padding(HarnessMonitorTheme.spacingSM)
          .shadow(radius: 8, y: 2)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: previewHeight)
      .background {
        outerShape
          .fill(isSelected ? HarnessMonitorTheme.accent : Color.clear)
      }
      .clipShape(outerShape)
      .overlay {
        outerShape
          .strokeBorder(
            isSelected ? Color.clear : HarnessMonitorTheme.controlBorder.opacity(0.55),
            lineWidth: isSelected ? 0 : 1
          )
      }
      .contentShape(outerShape)
    }
    .buttonStyle(.plain)
    .harnessInteractiveCardButtonStyle(
      cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
      tint: isSelected ? HarnessMonitorTheme.accent : nil
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(background.label)
    .accessibilityValue(isSelected ? "selected" : background.subtitle)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesBackgroundTile(background.accessibilityKey))
    .task(id: background.storageValue) {
      loadedImage = nil
      guard let cgImage = await BackgroundThumbnailCache.shared.thumbnail(for: background) else {
        return
      }
      let size = NSSize(width: cgImage.width, height: cgImage.height)
      loadedImage = Image(nsImage: NSImage(cgImage: cgImage, size: size))
    }
  }

  @ViewBuilder
  private var previewContent: some View {
    if let loadedImage {
      loadedImage
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fill)
        .accessibilityHidden(true)
    } else {
      Color.secondary.opacity(0.08)
        .overlay {
          HarnessMonitorSpinner(size: 16)
        }
        .accessibilityHidden(true)
    }
  }
}
